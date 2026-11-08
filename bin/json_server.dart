import 'dart:io';

import 'package:json_server/json_server.dart';

Future<void> main(List<String> arguments) async {
  final options = _parseArguments(arguments);
  final server = JsonServer(
    file: options.file,
    host: options.host,
    port: options.port,
    watch: options.watch,
  );

  try {
    final httpServer = await server.start();
    stdout.writeln(
      'JSON Server is running on http://${options.host}:${httpServer.port}',
    );
    stdout.writeln('Serving ${File(options.file).absolute.path}');
  } on FileSystemException catch (error) {
    stderr.writeln(
      'Could not read database file "${options.file}": ${error.message}',
    );
    exitCode = 1;
  } on FormatException catch (error) {
    stderr.writeln('Invalid database file: ${error.message}');
    exitCode = 1;
  } on SocketException catch (error) {
    stderr.writeln('Could not start server: ${error.message}');
    exitCode = 1;
  }
}

_Options _parseArguments(List<String> arguments) {
  String? file;
  var host = '0.0.0.0';
  var port = 3000;
  var watch = false;

  for (var index = 0; index < arguments.length; index++) {
    final argument = arguments[index];

    if (argument == '-h' || argument == '--help') {
      _printUsage();
      exit(0);
    }
    if (argument == '-w' || argument == '--watch') {
      watch = true;
      continue;
    }
    if (argument == '-p' || argument == '--port') {
      port = _parsePort(_optionValue(arguments, ++index, argument));
      continue;
    }
    if (argument.startsWith('--port=')) {
      port = _parsePort(argument.substring('--port='.length));
      continue;
    }
    if (argument == '-H' || argument == '--host') {
      host = _optionValue(arguments, ++index, argument);
      if (host.isEmpty) {
        _fail('Host cannot be empty.');
      }
      continue;
    }
    if (argument.startsWith('--host=')) {
      host = argument.substring('--host='.length);
      if (host.isEmpty) {
        _fail('Host cannot be empty.');
      }
      continue;
    }
    if (argument.startsWith('-')) {
      _fail('Unknown option: $argument');
    }
    if (file != null) {
      _fail('Only one database file can be provided.');
    }
    file = argument;
  }

  if (file == null) {
    _fail('A JSON database file is required.');
  }

  return _Options(file: file, host: host, port: port, watch: watch);
}

String _optionValue(List<String> arguments, int index, String option) {
  if (index >= arguments.length) {
    _fail('Missing value for $option.');
  }
  return arguments[index];
}

int _parsePort(String value) {
  final port = int.tryParse(value);
  if (port == null || port < 1 || port > 65535) {
    _fail('Port must be a number between 1 and 65535.');
  }
  return port;
}

Never _fail(String message) {
  stderr.writeln(message);
  stderr.writeln();
  _printUsage(toStandardError: true);
  exit(64);
}

void _printUsage({bool toStandardError = false}) {
  final output = toStandardError ? stderr : stdout;
  output.writeln('Usage: json-server <file> [options]');
  output.writeln();
  output.writeln('Options:');
  output.writeln('  -p, --port <port>   Port to listen on (default: 3000)');
  output.writeln('  -H, --host <host>   Host to bind to (default: 0.0.0.0)');
  output.writeln(
    '  -w, --watch         Reload the database when the file changes',
  );
  output.writeln('  -h, --help          Show this help message');
  output.writeln();
  output.writeln('Example:');
  output.writeln('  json-server db.json --port 3000');
}

class _Options {
  const _Options({
    required this.file,
    required this.host,
    required this.port,
    required this.watch,
  });

  final String file;
  final String host;
  final int port;
  final bool watch;
}
