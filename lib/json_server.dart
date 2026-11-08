import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'src/request_logger.dart';

const _reservedParameters = {
  '_page',
  '_limit',
  '_start',
  '_end',
  '_sort',
  '_order',
  '_embed',
  '_expand',
  'q',
};

const _irregularPlurals = {
  'people': 'person',
  'children': 'child',
  'men': 'man',
  'women': 'woman',
};

class JsonServer {
  JsonServer({
    required this.file,
    this.host = '0.0.0.0',
    this.port = 3000,
    this.watch = false,
    this.logRequests = true,
  });

  final String file;
  final String host;
  final int port;
  final bool watch;
  final bool logRequests;

  Map<String, dynamic> _database = {};
  HttpServer? _server;
  StreamSubscription<FileSystemEvent>? _watchSubscription;
  Timer? _reloadTimer;
  late final RequestLogger _logger = RequestLogger(enabled: logRequests);

  Map<String, dynamic> get database => _database;

  HttpServer get httpServer {
    final server = _server;
    if (server == null) {
      throw StateError('The server has not been started.');
    }
    return server;
  }

  Future<HttpServer> start() async {
    await _load();
    final server = await HttpServer.bind(host, port);
    _server = server;
    if (watch) {
      _watchFile();
    }
    server.listen((request) {
      unawaited(_handleRequest(request));
    });
    return server;
  }

  Future<void> close() async {
    _reloadTimer?.cancel();
    await _watchSubscription?.cancel();
    _watchSubscription = null;
    await _server?.close(force: true);
    _server = null;
  }

  Future<void> _load() async {
    final contents = await File(file).readAsString();
    final decoded = jsonDecode(contents);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException(
        'The database file must contain a JSON object at the top level.',
      );
    }
    _database = decoded;
  }

  void _watchFile() {
    final databaseFile = File(file).absolute;
    _watchSubscription = databaseFile.parent.watch().listen((event) {
      if (File(event.path).absolute.path != databaseFile.path) {
        return;
      }
      _reloadTimer?.cancel();
      _reloadTimer = Timer(const Duration(milliseconds: 150), () async {
        try {
          await _load();
        } catch (error) {
          stderr.writeln('Could not reload "$file": $error');
        }
      });
    });
  }

  Future<void> _handleRequest(HttpRequest request) async {
    final stopwatch = Stopwatch()..start();
    final response = request.response;
    _setCorsHeaders(response);
    try {
      if (request.method == 'OPTIONS') {
        response.statusCode = HttpStatus.noContent;
        await response.close();
        return;
      }
      await _dispatch(request);
    } on _HttpError catch (error) {
      await _sendJson(response, {
        'error': error.message,
      }, statusCode: error.statusCode);
    } catch (error, stackTrace) {
      stderr.writeln(
        'Error while handling ${request.method} ${request.uri}: '
        '$error\n$stackTrace',
      );
      try {
        await _sendJson(response, {
          'error': 'Internal Server Error',
        }, statusCode: HttpStatus.internalServerError);
      } catch (_) {
        try {
          await response.close();
        } catch (_) {}
      }
    } finally {
      stopwatch.stop();
      _logger.log(
        method: request.method,
        uri: request.uri,
        statusCode: response.statusCode,
        duration: stopwatch.elapsed,
        remoteAddress: request.connectionInfo?.remoteAddress.address,
      );
    }
  }

  Future<void> _dispatch(HttpRequest request) async {
    final segments = request.uri.pathSegments
        .where((segment) => segment.isNotEmpty)
        .toList();

    if (segments.isEmpty) {
      if (request.method != 'GET') {
        throw const _HttpError(
          HttpStatus.methodNotAllowed,
          'Method Not Allowed',
        );
      }
      await _sendJson(request.response, _database);
      return;
    }

    final collectionName = segments.first;
    if (segments.length == 1 && collectionName == 'db') {
      if (request.method != 'GET') {
        throw const _HttpError(
          HttpStatus.methodNotAllowed,
          'Method Not Allowed',
        );
      }
      await _sendJson(request.response, _database);
      return;
    }
    if (!_database.containsKey(collectionName)) {
      throw const _HttpError(HttpStatus.notFound, 'Not Found');
    }
    final resource = _database[collectionName];

    if (segments.length == 1) {
      if (resource is List) {
        switch (request.method) {
          case 'GET':
            await _getCollection(request, collectionName, resource);
            return;
          case 'POST':
            await _createItem(request, collectionName, resource);
            return;
          default:
            throw const _HttpError(
              HttpStatus.methodNotAllowed,
              'Method Not Allowed',
            );
        }
      }
      if (resource is Map<String, dynamic>) {
        switch (request.method) {
          case 'GET':
            await _getSingular(request, collectionName, resource);
            return;
          case 'POST':
            await _createSingular(request, collectionName);
            return;
          case 'PUT':
          case 'PATCH':
            await _updateSingular(request, collectionName, resource);
            return;
          default:
            throw const _HttpError(
              HttpStatus.methodNotAllowed,
              'Method Not Allowed',
            );
        }
      }
      throw const _HttpError(HttpStatus.notFound, 'Not Found');
    }

    final id = segments[1];

    if (segments.length == 2) {
      if (resource is! List) {
        throw const _HttpError(HttpStatus.notFound, 'Not Found');
      }
      final index = _indexOfId(resource, id);
      switch (request.method) {
        case 'GET':
          if (index < 0) {
            throw const _HttpError(HttpStatus.notFound, 'Not Found');
          }
          final item = _asMap(resource[index]);
          await _sendJson(
            request.response,
            _transform(item, collectionName, request.uri.queryParametersAll),
          );
          return;
        case 'PUT':
          if (index < 0) {
            throw const _HttpError(HttpStatus.notFound, 'Not Found');
          }
          await _replaceItem(request, resource, index);
          return;
        case 'PATCH':
          if (index < 0) {
            throw const _HttpError(HttpStatus.notFound, 'Not Found');
          }
          await _patchItem(request, resource, index);
          return;
        case 'DELETE':
          if (index < 0) {
            throw const _HttpError(HttpStatus.notFound, 'Not Found');
          }
          await _deleteItem(request, resource, index);
          return;
        default:
          throw const _HttpError(
            HttpStatus.methodNotAllowed,
            'Method Not Allowed',
          );
      }
    }

    if (segments.length == 3 || segments.length == 4) {
      await _handleNested(request, collectionName, resource, segments);
      return;
    }

    throw const _HttpError(HttpStatus.notFound, 'Not Found');
  }

  Future<void> _getCollection(
    HttpRequest request,
    String collectionName,
    List<dynamic> items,
  ) async {
    final result = _query(
      items,
      collectionName,
      request.uri.queryParametersAll,
    );
    await _sendJson(
      request.response,
      result.items,
      headers: {'X-Total-Count': '${result.total}'},
    );
  }

  Future<void> _getSingular(
    HttpRequest request,
    String collectionName,
    Map<String, dynamic> item,
  ) async {
    await _sendJson(
      request.response,
      _transform(item, collectionName, request.uri.queryParametersAll),
    );
  }

  Future<void> _createSingular(
    HttpRequest request,
    String collectionName,
  ) async {
    final body = await _readJsonBody(request);
    if (body is! Map<String, dynamic>) {
      throw const _HttpError(
        HttpStatus.badRequest,
        'Request body must be a JSON object.',
      );
    }
    final item = Map<String, dynamic>.from(body);
    _database[collectionName] = item;
    await _persist();
    await _sendJson(request.response, item, statusCode: HttpStatus.created);
  }

  Future<void> _createItem(
    HttpRequest request,
    String collectionName,
    List<dynamic> items, {
    Map<String, dynamic>? defaults,
  }) async {
    final body = await _readJsonBody(request);
    if (body is! Map<String, dynamic>) {
      throw const _HttpError(
        HttpStatus.badRequest,
        'Request body must be a JSON object.',
      );
    }
    final item = Map<String, dynamic>.from(body);
    if (defaults != null) {
      item.addAll(defaults);
    }
    final suppliedId = item['id'];
    if (suppliedId != null && _indexOfId(items, suppliedId.toString()) >= 0) {
      item['id'] = _nextId(items);
    }
    item.putIfAbsent('id', () => _nextId(items));
    items.add(item);
    await _persist();
    await _sendJson(request.response, item, statusCode: HttpStatus.created);
  }

  Future<void> _replaceItem(
    HttpRequest request,
    List<dynamic> items,
    int index, {
    Map<String, dynamic>? defaults,
  }) async {
    final body = await _readJsonBody(request);
    if (body is! Map<String, dynamic>) {
      throw const _HttpError(
        HttpStatus.badRequest,
        'Request body must be a JSON object.',
      );
    }
    final existing = items[index];
    final item = Map<String, dynamic>.from(body);
    item['id'] = existing is Map ? existing['id'] : null;
    if (item['id'] == null) {
      item.remove('id');
    }
    if (defaults != null) {
      item.addAll(defaults);
    }
    items[index] = item;
    await _persist();
    await _sendJson(request.response, item);
  }

  Future<void> _patchItem(
    HttpRequest request,
    List<dynamic> items,
    int index, {
    Map<String, dynamic>? defaults,
  }) async {
    final body = await _readJsonBody(request);
    if (body is! Map<String, dynamic>) {
      throw const _HttpError(
        HttpStatus.badRequest,
        'Request body must be a JSON object.',
      );
    }
    final existing = _asMap(items[index]);
    final item = Map<String, dynamic>.from(existing)..addAll(body);
    if (existing.containsKey('id')) {
      item['id'] = existing['id'];
    }
    if (defaults != null) {
      item.addAll(defaults);
    }
    items[index] = item;
    await _persist();
    await _sendJson(request.response, item);
  }

  Future<void> _deleteItem(
    HttpRequest request,
    List<dynamic> items,
    int index,
  ) async {
    items.removeAt(index);
    await _persist();
    await _sendJson(request.response, <String, dynamic>{});
  }

  Future<void> _updateSingular(
    HttpRequest request,
    String collectionName,
    Map<String, dynamic> existing,
  ) async {
    final body = await _readJsonBody(request);
    if (body is! Map<String, dynamic>) {
      throw const _HttpError(
        HttpStatus.badRequest,
        'Request body must be a JSON object.',
      );
    }
    final updated = request.method == 'PUT'
        ? Map<String, dynamic>.from(body)
        : (Map<String, dynamic>.from(existing)..addAll(body));
    _database[collectionName] = updated;
    await _persist();
    await _sendJson(request.response, updated);
  }

  Future<void> _handleNested(
    HttpRequest request,
    String parentName,
    dynamic parentResource,
    List<String> segments,
  ) async {
    if (parentResource is! List) {
      throw const _HttpError(HttpStatus.notFound, 'Not Found');
    }

    final parentIndex = _indexOfId(parentResource, segments[1]);
    if (parentIndex < 0) {
      throw const _HttpError(HttpStatus.notFound, 'Not Found');
    }
    final parent = _asMap(parentResource[parentIndex]);

    final childName = segments[2];
    final childResource = _database[childName];
    if (childResource is! List) {
      throw const _HttpError(HttpStatus.notFound, 'Not Found');
    }

    final foreignKey = _foreignKeyFor(parentName, childResource);
    final related = childResource
        .where(
          (item) => item is Map && _idEquals(item[foreignKey], parent['id']),
        )
        .toList();

    if (segments.length == 3) {
      switch (request.method) {
        case 'GET':
          final result = _query(
            related,
            childName,
            request.uri.queryParametersAll,
          );
          await _sendJson(
            request.response,
            result.items,
            headers: {'X-Total-Count': '${result.total}'},
          );
          return;
        case 'POST':
          await _createItem(
            request,
            childName,
            childResource,
            defaults: {foreignKey: parent['id']},
          );
          return;
        default:
          throw const _HttpError(
            HttpStatus.methodNotAllowed,
            'Method Not Allowed',
          );
      }
    }

    final relatedIndex = _indexOfId(related, segments[3]);
    if (relatedIndex < 0) {
      throw const _HttpError(HttpStatus.notFound, 'Not Found');
    }
    final index = childResource.indexOf(related[relatedIndex]);
    final defaults = {foreignKey: parent['id']};

    switch (request.method) {
      case 'GET':
        await _sendJson(
          request.response,
          _transform(
            _asMap(childResource[index]),
            childName,
            request.uri.queryParametersAll,
          ),
        );
        return;
      case 'PUT':
        await _replaceItem(request, childResource, index, defaults: defaults);
        return;
      case 'PATCH':
        await _patchItem(request, childResource, index, defaults: defaults);
        return;
      case 'DELETE':
        await _deleteItem(request, childResource, index);
        return;
      default:
        throw const _HttpError(
          HttpStatus.methodNotAllowed,
          'Method Not Allowed',
        );
    }
  }

  _QueryResult _query(
    List<dynamic> source,
    String collectionName,
    Map<String, List<String>> parameters,
  ) {
    var items = source
        .where((item) => item is! Map || _matchesFilters(item, parameters))
        .toList();

    final sortFields = _commaParameter(parameters, '_sort');
    if (sortFields.isNotEmpty) {
      final orders = _commaParameter(parameters, '_order');
      final indexed = items.asMap().entries.toList();
      indexed.sort((left, right) {
        for (var index = 0; index < sortFields.length; index++) {
          final comparison = _compareValues(
            _lookup(left.value, sortFields[index]),
            _lookup(right.value, sortFields[index]),
          );
          if (comparison == 0) {
            continue;
          }
          final descending =
              orders.length > index && orders[index].toLowerCase() == 'desc';
          return descending ? -comparison : comparison;
        }
        return left.key.compareTo(right.key);
      });
      items = indexed.map((entry) => entry.value).toList();
    }

    items = items
        .map((item) => _transform(item, collectionName, parameters))
        .toList();

    final total = items.length;
    final page = _intParameter(parameters, '_page');
    final limit = _intParameter(parameters, '_limit');
    final start = _intParameter(parameters, '_start');
    final end = _intParameter(parameters, '_end');

    if (page != null) {
      final perPage = limit ?? 10;
      final from = (page - 1) * perPage;
      items = _slice(items, from, from + perPage);
    } else if (end != null) {
      items = _slice(items, start ?? 0, end);
    } else if (limit != null) {
      final from = start ?? 0;
      items = _slice(items, from, from + limit);
    }

    return _QueryResult(items, total);
  }

  bool _matchesFilters(
    Map<dynamic, dynamic> item,
    Map<String, List<String>> parameters,
  ) {
    final search = parameters['q']?.last;
    if (search != null &&
        search.isNotEmpty &&
        !_searchText(item).toLowerCase().contains(search.toLowerCase())) {
      return false;
    }

    for (final parameter in parameters.entries) {
      var key = parameter.key;
      if (key == 'q' || _reservedParameters.contains(key)) {
        continue;
      }

      String? operator;
      for (final candidate in const ['_gte', '_lte', '_ne', '_like']) {
        if (key.endsWith(candidate)) {
          operator = candidate;
          key = key.substring(0, key.length - candidate.length);
          break;
        }
      }
      if (key.isEmpty) {
        continue;
      }

      final actual = _lookup(item, key);
      final matches = parameter.value.any(
        (expected) => _matchesValue(actual, expected, operator),
      );
      if (!matches) {
        return false;
      }
    }
    return true;
  }

  bool _matchesValue(dynamic actual, String expected, String? operator) {
    switch (operator) {
      case '_ne':
        return !_equalsValue(actual, expected);
      case '_gte':
        return actual != null && _compareValue(actual, expected) >= 0;
      case '_lte':
        return actual != null && _compareValue(actual, expected) <= 0;
      case '_like':
        try {
          return RegExp(
            expected,
            caseSensitive: false,
          ).hasMatch(actual?.toString() ?? '');
        } on FormatException {
          return false;
        }
      default:
        return _equalsValue(actual, expected);
    }
  }

  bool _equalsValue(dynamic actual, String expected) {
    if (actual == null) {
      return expected == 'null';
    }
    if (actual is bool) {
      return actual.toString() == expected.toLowerCase();
    }
    if (actual is num) {
      final number = num.tryParse(expected);
      return number != null && actual == number;
    }
    if (actual is Iterable) {
      return actual.any((value) => _equalsValue(value, expected));
    }
    return actual.toString() == expected;
  }

  int _compareValue(dynamic actual, String expected) {
    if (actual is num) {
      final number = num.tryParse(expected);
      if (number != null) {
        return actual.compareTo(number);
      }
    }
    return actual.toString().compareTo(expected);
  }

  int _compareValues(dynamic left, dynamic right) {
    if (left == null && right == null) {
      return 0;
    }
    if (left == null) {
      return 1;
    }
    if (right == null) {
      return -1;
    }
    if (left is num && right is num) {
      return left.compareTo(right);
    }
    return left.toString().compareTo(right.toString());
  }

  dynamic _lookup(dynamic item, String field) {
    if (item is! Map) {
      return null;
    }
    if (item.containsKey(field)) {
      return item[field];
    }
    if (field.contains('.')) {
      dynamic current = item;
      for (final part in field.split('.')) {
        if (current is! Map || !current.containsKey(part)) {
          return null;
        }
        current = current[part];
      }
      return current;
    }
    return null;
  }

  String _searchText(dynamic value) {
    if (value is Map) {
      return value.values.map(_searchText).join(' ');
    }
    if (value is Iterable) {
      return value.map(_searchText).join(' ');
    }
    if (value == null) {
      return '';
    }
    return value.toString();
  }

  dynamic _transform(
    dynamic item,
    String collectionName,
    Map<String, List<String>> parameters,
  ) {
    if (item is! Map<String, dynamic>) {
      return item;
    }
    final result = Map<String, dynamic>.from(item);

    for (final childName in _commaParameter(parameters, '_embed')) {
      final childCollection = _collectionFor(childName);
      if (childCollection == null) {
        continue;
      }
      final childItems = _database[childCollection];
      if (childItems is! List) {
        continue;
      }
      final foreignKey = _foreignKeyFor(collectionName, childItems);
      result[childName] = childItems
          .where(
            (child) =>
                child is Map && _idEquals(child[foreignKey], result['id']),
          )
          .toList();
    }

    for (final parentName in _commaParameter(parameters, '_expand')) {
      final parentCollection = _collectionFor(parentName);
      if (parentCollection == null) {
        continue;
      }
      final parentItems = _database[parentCollection];
      if (parentItems is! List) {
        continue;
      }
      final candidates = [
        '${parentName}Id',
        '${_singularize(parentCollection)}Id',
        '${parentCollection}Id',
      ];
      final foreignKey = candidates.firstWhere(
        result.containsKey,
        orElse: () => candidates.first,
      );
      final parentId = result[foreignKey];
      for (final parent in parentItems) {
        if (parent is Map && _idEquals(parent['id'], parentId)) {
          result[parentName] = parent;
          break;
        }
      }
    }

    return result;
  }

  String? _collectionFor(String name) {
    if (_database.containsKey(name)) {
      return name;
    }
    for (final key in _database.keys) {
      if (_database[key] is List && _singularize(key) == name) {
        return key;
      }
    }
    return null;
  }

  String _foreignKeyFor(String parentCollection, List<dynamic> children) {
    final singular = _singularize(parentCollection);
    final candidates = [
      '${singular}Id',
      '${singular}_id',
      '${parentCollection}Id',
      '${parentCollection}_id',
    ];
    for (final candidate in candidates) {
      if (children.any(
        (child) => child is Map && child.containsKey(candidate),
      )) {
        return candidate;
      }
    }
    return candidates.first;
  }

  String _singularize(String word) {
    final irregular = _irregularPlurals[word.toLowerCase()];
    if (irregular != null) {
      return irregular;
    }
    if (word.endsWith('ies') && word.length > 3) {
      return '${word.substring(0, word.length - 3)}y';
    }
    if (word.endsWith('ses') && word.length > 3) {
      return word.substring(0, word.length - 2);
    }
    if (word.endsWith('s') && word.length > 1) {
      return word.substring(0, word.length - 1);
    }
    return word;
  }

  int _indexOfId(List<dynamic> items, String id) {
    return items.indexWhere((item) => item is Map && _idEquals(item['id'], id));
  }

  bool _idEquals(dynamic left, dynamic right) {
    if (left == null || right == null) {
      return false;
    }
    if (left is num && right is num) {
      return left == right;
    }
    return left.toString() == right.toString();
  }

  dynamic _nextId(List<dynamic> items) {
    var maximum = 0;
    for (final item in items) {
      if (item is! Map) {
        continue;
      }
      final value = item['id'];
      final number = value is num ? value : num.tryParse('$value');
      if (number != null && number > maximum) {
        maximum = number.toInt();
      }
    }
    return maximum + 1;
  }

  Map<String, dynamic> _asMap(dynamic value) {
    if (value is Map<String, dynamic>) {
      return value;
    }
    if (value is Map) {
      return Map<String, dynamic>.from(value);
    }
    throw const _HttpError(
      HttpStatus.internalServerError,
      'Resource is not a JSON object.',
    );
  }

  List<dynamic> _slice(List<dynamic> items, int start, int end) {
    final from = _clamp(start, 0, items.length);
    final to = _clamp(end, from, items.length);
    return items.sublist(from, to);
  }

  int _clamp(int value, int minimum, int maximum) {
    if (value < minimum) {
      return minimum;
    }
    if (value > maximum) {
      return maximum;
    }
    return value;
  }

  List<String> _commaParameter(
    Map<String, List<String>> parameters,
    String name,
  ) {
    final values = parameters[name];
    if (values == null) {
      return const [];
    }
    return values
        .expand((value) => value.split(','))
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toList();
  }

  int? _intParameter(Map<String, List<String>> parameters, String name) {
    final value = parameters[name]?.last;
    if (value == null) {
      return null;
    }
    return int.tryParse(value);
  }

  Future<dynamic> _readJsonBody(HttpRequest request) async {
    final contents = await utf8.decoder.bind(request).join();
    if (contents.trim().isEmpty) {
      throw const _HttpError(
        HttpStatus.badRequest,
        'Request body is required.',
      );
    }
    try {
      return jsonDecode(contents);
    } on FormatException {
      throw const _HttpError(
        HttpStatus.badRequest,
        'Request body must be valid JSON.',
      );
    }
  }

  Future<void> _persist() async {
    const encoder = JsonEncoder.withIndent('  ');
    await File(file).writeAsString('${encoder.convert(_database)}\n');
  }

  void _setCorsHeaders(HttpResponse response) {
    response.headers
      ..set('Access-Control-Allow-Origin', '*')
      ..set(
        'Access-Control-Allow-Methods',
        'GET, POST, PUT, PATCH, DELETE, OPTIONS',
      )
      ..set('Access-Control-Allow-Headers', 'Content-Type, Authorization')
      ..set('Access-Control-Expose-Headers', 'X-Total-Count');
  }

  Future<void> _sendJson(
    HttpResponse response,
    Object? body, {
    int statusCode = HttpStatus.ok,
    Map<String, String> headers = const {},
  }) async {
    response.statusCode = statusCode;
    response.headers.contentType = ContentType.json;
    headers.forEach(response.headers.set);
    response.write(jsonEncode(body));
    await response.close();
  }
}

class _QueryResult {
  const _QueryResult(this.items, this.total);

  final List<dynamic> items;
  final int total;
}

class _HttpError implements Exception {
  const _HttpError(this.statusCode, this.message);

  final int statusCode;
  final String message;
}
