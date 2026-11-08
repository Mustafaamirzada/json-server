import 'dart:convert';
import 'dart:io';

import 'package:json_server/json_server.dart';
import 'package:test/test.dart';

const _initialDatabase = {
  'posts': [
    {
      'id': 1,
      'title': 'First post',
      'views': 100,
      'published': true,
      'author': {'name': 'Alice'},
    },
    {
      'id': 2,
      'title': 'Second post',
      'views': 250,
      'published': false,
      'author': {'name': 'Bob'},
    },
    {
      'id': 3,
      'title': 'Another post',
      'views': 250,
      'published': true,
      'author': {'name': 'Alice'},
    },
  ],
  'comments': [
    {'id': 1, 'postId': 1, 'body': 'Nice'},
    {'id': 2, 'postId': 1, 'body': 'Great'},
    {'id': 3, 'postId': 2, 'body': 'Hmm'},
  ],
  'profile': {'name': 'Mustafa', 'role': 'admin'},
};

void main() {
  late Directory temporaryDirectory;
  late File databaseFile;
  late JsonServer server;
  late HttpClient client;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'json_server_test_',
    );
    databaseFile = File('${temporaryDirectory.path}/db.json');
    await databaseFile.writeAsString(jsonEncode(_initialDatabase));

    server = JsonServer(
      file: databaseFile.path,
      host: '127.0.0.1',
      port: 0,
      logRequests: false,
    );
    await server.start();
    client = HttpClient();
  });

  tearDown(() async {
    client.close(force: true);
    await server.close();
    await temporaryDirectory.delete(recursive: true);
  });

  Future<_TestResponse> request(
    String method,
    String path, {
    Object? body,
  }) async {
    final request = await client.openUrl(
      method,
      Uri.parse('http://127.0.0.1:${server.httpServer.port}$path'),
    );
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
    }
    final response = await request.close();
    final contents = await response.transform(utf8.decoder).join();
    return _TestResponse(
      response.statusCode,
      contents.isEmpty ? null : jsonDecode(contents),
      response.headers,
    );
  }

  test('serves the database root and collections', () async {
    final root = await request('GET', '/');
    expect(root.statusCode, HttpStatus.ok);
    expect((root.body as Map<String, dynamic>)['posts'], hasLength(3));

    final posts = await request('GET', '/posts');
    expect(posts.statusCode, HttpStatus.ok);
    expect(posts.body, hasLength(3));
    expect(posts.headers.value('x-total-count'), '3');
    expect(posts.headers.value('access-control-allow-origin'), '*');
  });

  test('serves the database through /db', () async {
    final response = await request('GET', '/db');
    expect(response.statusCode, HttpStatus.ok);
    expect((response.body as Map<String, dynamic>)['comments'], hasLength(3));
  });

  test('serves single items and returns 404 for missing ids', () async {
    final post = await request('GET', '/posts/1');
    expect(post.statusCode, HttpStatus.ok);
    expect((post.body as Map<String, dynamic>)['title'], 'First post');

    final missing = await request('GET', '/posts/999');
    expect(missing.statusCode, HttpStatus.notFound);
    expect((missing.body as Map<String, dynamic>)['error'], 'Not Found');
  });

  test('filters, searches, sorts and paginates collections', () async {
    final filtered = await request('GET', '/posts?published=true');
    expect(filtered.body, hasLength(2));
    expect(filtered.headers.value('x-total-count'), '2');

    final search = await request('GET', '/posts?q=alice');
    expect(search.body, hasLength(2));

    final nestedField = await request('GET', '/posts?author.name=Alice');
    expect(nestedField.body, hasLength(2));

    final sorted = await request(
      'GET',
      '/posts?views_gte=200&_sort=title&_order=asc',
    );
    expect((sorted.body as List).map((post) => (post as Map)['id']), [3, 2]);

    final paged = await request('GET', '/posts?_page=2&_limit=1&_sort=id');
    expect((paged.body as List).single['id'], 2);
    expect(paged.headers.value('x-total-count'), '3');

    final sliced = await request('GET', '/posts?_start=1&_limit=1&_sort=id');
    expect((sliced.body as List).single['id'], 2);

    final like = await request('GET', '/posts?title_like=FIRST');
    expect((like.body as List).single['id'], 1);
  });

  test('supports CRUD operations and persists changes to disk', () async {
    final created = await request(
      'POST',
      '/posts',
      body: {'title': 'New post', 'views': 0},
    );
    expect(created.statusCode, HttpStatus.created);
    final createdPost = created.body as Map<String, dynamic>;
    expect(createdPost['id'], 4);

    var stored =
        jsonDecode(await databaseFile.readAsString()) as Map<String, dynamic>;
    expect(stored['posts'], hasLength(4));

    final replaced = await request(
      'PUT',
      '/posts/4',
      body: {'title': 'Replaced post', 'views': 5},
    );
    expect(replaced.body, {'title': 'Replaced post', 'views': 5, 'id': 4});

    final patched = await request('PATCH', '/posts/4', body: {'views': 6});
    expect((patched.body as Map<String, dynamic>)['views'], 6);
    expect((patched.body as Map<String, dynamic>)['title'], 'Replaced post');

    final deleted = await request('DELETE', '/posts/4');
    expect(deleted.statusCode, HttpStatus.ok);
    expect(deleted.body, <String, dynamic>{});

    stored =
        jsonDecode(await databaseFile.readAsString()) as Map<String, dynamic>;
    expect(stored['posts'], hasLength(3));
    expect((await request('GET', '/posts/4')).statusCode, HttpStatus.notFound);
  });

  test('supports nested resources', () async {
    final comments = await request('GET', '/posts/1/comments');
    expect(comments.statusCode, HttpStatus.ok);
    expect(comments.body, hasLength(2));
    expect(comments.headers.value('x-total-count'), '2');

    final comment = await request('GET', '/posts/1/comments/2');
    expect((comment.body as Map<String, dynamic>)['body'], 'Great');

    final created = await request(
      'POST',
      '/posts/1/comments',
      body: {'body': 'Added'},
    );
    expect(created.statusCode, HttpStatus.created);
    expect((created.body as Map<String, dynamic>)['postId'], 1);
    expect((created.body as Map<String, dynamic>)['id'], 4);

    final stored =
        jsonDecode(await databaseFile.readAsString()) as Map<String, dynamic>;
    expect(stored['comments'], hasLength(4));
  });

  test('embeds children and expands parents', () async {
    final embedded = await request('GET', '/posts/1?_embed=comments');
    expect((embedded.body as Map<String, dynamic>)['comments'], hasLength(2));

    final expanded = await request('GET', '/comments/1?_expand=post');
    final post = (expanded.body as Map<String, dynamic>)['post'];
    expect((post as Map<String, dynamic>)['title'], 'First post');
  });

  test('supports singular resources', () async {
    final profile = await request('GET', '/profile');
    expect((profile.body as Map<String, dynamic>)['name'], 'Mustafa');

    final patched = await request('PATCH', '/profile', body: {'role': 'user'});
    expect(patched.body, {'name': 'Mustafa', 'role': 'user'});

    final replaced = await request(
      'PUT',
      '/profile',
      body: {'name': 'New name'},
    );
    expect(replaced.body, {'name': 'New name'});

    final stored =
        jsonDecode(await databaseFile.readAsString()) as Map<String, dynamic>;
    expect(stored['profile'], {'name': 'New name'});

    final created = await request(
      'POST',
      '/profile',
      body: {'name': 'Created'},
    );
    expect(created.statusCode, HttpStatus.created);
    expect(created.body, {'name': 'Created'});
    expect((await request('GET', '/profile')).body, {'name': 'Created'});
  });

  test('answers CORS preflight requests', () async {
    final response = await request('OPTIONS', '/posts');
    expect(response.statusCode, HttpStatus.noContent);
    expect(response.headers.value('access-control-allow-origin'), '*');
    expect(
      response.headers.value('access-control-allow-methods'),
      contains('PATCH'),
    );
  });

  test('rejects invalid JSON request bodies', () async {
    final request = await client.openUrl(
      'POST',
      Uri.parse('http://127.0.0.1:${server.httpServer.port}/posts'),
    );
    request.headers.contentType = ContentType.json;
    request.write('{invalid');
    final response = await request.close();
    final contents = await response.transform(utf8.decoder).join();

    expect(response.statusCode, HttpStatus.badRequest);
    expect(
      (jsonDecode(contents) as Map<String, dynamic>)['error'],
      'Request body must be valid JSON.',
    );
  });
}

class _TestResponse {
  const _TestResponse(this.statusCode, this.body, this.headers);

  final int statusCode;
  final dynamic body;
  final HttpHeaders headers;
}
