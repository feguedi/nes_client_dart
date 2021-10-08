enum ErrorTypes {
  TIMEOUT,
  DISCONNECT,
  SERVER,
  PROTOCOL,
  WS,
  USER,
}

class _NesException implements Exception {
  String cause;
  _NesException(this.cause);
}

class _NesError extends Error {
  ErrorTypes? _type;
  bool? _isNes;

  ErrorTypes get type => _type ?? ErrorTypes.USER;
  bool get isNes => _isNes ?? true;

  set type(ErrorTypes val) {
    _type = val;
  }

  set isNes(bool val) {
    _isNes = val;
  }

  @override
  String toString() {
    final message = '';
    return '''Error:
    $message
    ''';
  }
}

class NesError {
  final Map<int, String> errorCodes = {
    1000: 'Normal closure',
    1001: 'Going away',
    1002: 'Protocol error',
    1003: 'Unsupported data',
    1004: 'Reserved',
    1005: 'No status received',
    1006: 'Abnormal closure',
    1007: 'Invalid frame payload data',
    1008: 'Policy violation',
    1009: 'Message too big',
    1010: 'Mandatory extension',
    1011: 'Internal server error',
    1015: 'TLS handshake',
  };

  final ErrorTypes type;
  final _NesError _nesError = _NesError();

  NesError(err, this.type) {
    if (err is String) {
      throw _throwException(err);
    } else if (err is Object) {
      _nesError.type = type;
      _nesError.isNes = true;
    }

    try {
      throw _nesError;
    } catch (e) {
      rethrow;
    }
  }

  _throwException(String message) {
    throw _NesException(message);
  }
}
