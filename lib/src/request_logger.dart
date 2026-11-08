import 'dart:io';

class RequestLogger {
  const RequestLogger({this.enabled = true});

  final bool enabled;

  void log({
    required String method,
    required Uri uri,
    required int statusCode,
    required Duration duration,
    String? remoteAddress,
  }) {
    if (!enabled) {
      return;
    }

    final timestamp = _formatTimestamp(DateTime.now());
    final remote = remoteAddress ?? '-';
    final target = _formatTarget(uri);
    final methodLabel = method.padRight(7);
    final statusLabel = statusCode.toString().padLeft(3);
    final durationLabel = _formatDuration(duration).padLeft(8);

    final line =
        '${_paint('[$timestamp]', _dim)} '
        '${_paint(remote.padRight(15), _dim)} '
        '${_paint(methodLabel, _methodColor(method))} '
        '$target '
        '${_paint(statusLabel, _statusColor(statusCode))} '
        '${_paint(durationLabel, _durationColor(duration))}';

    stdout.writeln(line);
  }

  String _formatTarget(Uri uri) {
    final path = uri.path.isEmpty ? '/' : uri.path;
    return uri.hasQuery ? '$path?${uri.query}' : path;
  }

  String _formatTimestamp(DateTime time) {
    String twoDigits(int value) => value.toString().padLeft(2, '0');
    return '${twoDigits(time.hour)}:${twoDigits(time.minute)}:'
        '${twoDigits(time.second)}';
  }

  String _formatDuration(Duration duration) {
    final microseconds = duration.inMicroseconds;
    if (microseconds < 1000) {
      return '$microsecondsµs';
    }
    final milliseconds = duration.inMilliseconds;
    if (milliseconds < 1000) {
      return '${(microseconds / 1000).toStringAsFixed(1)}ms';
    }
    return '${(microseconds / 1000000).toStringAsFixed(2)}s';
  }

  String _methodColor(String method) {
    return switch (method) {
      'GET' => _cyan,
      'POST' => _green,
      'PUT' => _yellow,
      'PATCH' => _magenta,
      'DELETE' => _red,
      'OPTIONS' => _blue,
      _ => _white,
    };
  }

  String _statusColor(int statusCode) {
    if (statusCode >= 500) {
      return _red;
    }
    if (statusCode >= 400) {
      return _yellow;
    }
    if (statusCode >= 300) {
      return _cyan;
    }
    if (statusCode >= 200) {
      return _green;
    }
    return _white;
  }

  String _durationColor(Duration duration) {
    final milliseconds = duration.inMilliseconds;
    if (milliseconds < 100) {
      return _green;
    }
    if (milliseconds < 500) {
      return _yellow;
    }
    return _red;
  }

  String _paint(String text, String color) {
    if (!stdout.supportsAnsiEscapes) {
      return text;
    }
    return '$color$text$_reset';
  }
}

const _reset = '\x1B[0m';
const _dim = '\x1B[2m';
const _red = '\x1B[31m';
const _green = '\x1B[32m';
const _yellow = '\x1B[33m';
const _blue = '\x1B[34m';
const _magenta = '\x1B[35m';
const _cyan = '\x1B[36m';
const _white = '\x1B[37m';
