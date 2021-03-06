enum ErrorTypes {
  TIMEOUT,
  DISCONNECT,
  SERVER,
  PROTOCOL,
  WS,
  USER,
}

Map<int, String> errorCodes = {
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

class _NesException implements Exception {
  String cause;
  _NesException(this.cause);

  @override
  String toString() {
    return 'NesException: $cause';
  }
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
    final message = _type.toString().replaceAll('ErrorTypes.', '');
    return 'NesError: $message';
  }
}

class NesError {
  final ErrorTypes errorType;
  String? _errorTypeString;
  late _NesError? _nesError;
  late _NesException? _nesException;

  NesError(err, this.errorType) {
    if (err is String) {
      _errorTypeString =
          '${errorType.toString().replaceAll('ErrorTypes.', '')}: $err';
      _nesException = _NesException(_errorTypeString!);
    } else if (err is Object) {
      _nesError = _NesError();
      _nesError!.type = errorType;
      _nesError!.isNes = true;
    }
  }

  @override
  String toString() => 'NesError: ${_errorTypeString ?? _nesError.toString()}';

  throwNesError() {
    if (_nesError != null) {
      throw _nesError!;
    } else if (_nesException != null) {
      throw _nesException!;
    }
  }
}
