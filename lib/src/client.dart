import 'dart:async';
import 'dart:collection' show HashMap;
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:web_socket_channel/io.dart';

import './nes_error.dart';

class NesClient {
  final String _version = '2';

  final String _url;
  _Settings _settings = _Settings.fromMap({});

  IOWebSocketChannel? _ws;
  _Reconnection? _reconnection;
  Timer? _reconnectionTimer;
  int _ids = 0;
  HashMap<String, _Record> _requests = HashMap.from({});
  HashMap<String, List<dynamic>> _subscriptions = HashMap.from({});
  Timer? _heartbeat;
  int? _heartbeatTimeout;
  List _packets = [];
  List<Function>? _disconnectListeners;
  bool? _disconnectRequested = false;

  String? id;

  _ignore([_]) {}
  _nextTick(Function cb) {
    return (err) => Timer(Duration(seconds: 0), cb(err));
  }

  final StreamController<List> _onDisconnectController =
      StreamController<List>();
  Stream<List> get onDisconnect => _onDisconnectController.stream;

  final StreamController<String?> _onUpdateController =
      StreamController<String?>();
  Stream<String?> get onUpdate => _onUpdateController.stream;

  // onError(err) => print(err);
  final StreamController<NesError> _onErrorController =
      StreamController<NesError>();
  Stream<NesError> get onError => _onErrorController.stream;

  final StreamController<String> _onConnectController =
      StreamController<String>();
  Stream<String> get onConnect => _onConnectController.stream;

  final StreamController<bool?> _onHeartbeatTimeoutController =
      StreamController<bool?>();
  Stream<bool?> get onHeartbeatTimeout => _onHeartbeatTimeoutController.stream;

  NesClient(this._url, [Map<String, dynamic>? options]) {
    _settings = options != null ? _Settings.fromMap(options) : _settings;
  }

  Future connect({
    auth,
    bool? reconnect,
    int? wait,
    int? delay,
    int? maxDelay,
    double? retries,
    int? timeout,
  }) {
    if (_reconnection != null) {
      return Future.error(NesError(
        'Cannot connect while client attempts to reconnect',
        ErrorTypes.USER,
      ));
    }
    if (_ws != null) {
      return Future.error(NesError('Already connected', ErrorTypes.USER));
    }

    final Map<String, dynamic>? _authMap =
        auth != null && auth is Map ? Map.from(auth) : null;

    final _Auth? _connectAuth = _authMap != null
        ? _Auth.fromMap(_authMap)
        : auth is String
            ? _Auth(token: auth)
            : null;

    if (reconnect != false) {
      _reconnection = _Reconnection(
        wait: wait,
        delay: delay ?? 1000,
        maxDelay: maxDelay ?? 5000,
        retries: retries ?? double.infinity,
        settings: _Settings(
          timeout: timeout,
          auth: _connectAuth,
        ),
      );
    } else {
      _reconnection = null;
    }

    return _connect(
      _ConnectOptions(
        auth: _connectAuth,
        timeout: timeout,
        delay: delay,
        maxDelay: maxDelay,
        retries: retries ?? double.infinity,
      ),
      true,
      (NesError? err) {
        if (err != null) {
          return Future.error(err);
        }
        return Future.value();
      },
    );
  }

  Future _connect(
    _ConnectOptions? options,
    bool initial, [
    Function(NesError? err)? next,
  ]) async {
    _ws = IOWebSocketChannel.connect(Uri.parse(_url));
    int timming = 1;

    while (_ws!.innerWebSocket == null) {
      await Future.delayed(Duration(seconds: timming));
      timming++;
      print('creating websocket');
    }

    _reconnectionTimer?.cancel();
    _reconnectionTimer = null;

    void finalize([NesError? err]) {
      // print('_connect finalize err: $err');
      try {
        if (next != null) {
          final nextHolder = next!;
          next = null;
          nextHolder(err);
        } else {
          _onErrorController.add(err ?? NesError('', ErrorTypes.USER));
        }
      } on NesError {
        // print('_connect finalize catch');
      } catch (e) {
        print(e);
      }
    }

    void reconnect([Map<String, dynamic>? event]) {
      print('_connect reconnect event: $event');
      try {
        if (_ws!.innerWebSocket?.readyState != WebSocket.open) {
          finalize(NesError(
            'Connection terminated while waiting to connect',
            ErrorTypes.WS,
          ));
        }
      } catch (e) {
        print(e);
      } finally {
        final bool? wasRequested = _disconnectRequested;

        _cleanup();

        final eventMap = event != null
            ? {
                ...event,
                'willReconnect': _willReconnect(),
                'wasRequested': wasRequested,
              }
            : null;
        final log = _Log.fromMap(eventMap ?? {});

        _onDisconnectController.add([log.willReconnect, log.toMap()]);
        _reconnect();
      }
    }

    timeoutHandler() {
      _cleanup();
      finalize(NesError('Connection timed out', ErrorTypes.TIMEOUT));
      if (initial) {
        return _reconnect();
      }
    }

    final Timer? timeout = options?.timeout != null
        ? Timer(Duration(milliseconds: options!.timeout!), timeoutHandler)
        : null;

    timeout?.cancel();

    _hello(options?.auth).then((value) {
      // print('_connect onOpen _hello value: $value');
      _onConnectController.add('Connected');
      finalize();
    }).catchError((err) {
      // print('_connect onOpen catchError: $err');
      if (err is Map<String, dynamic> && err['path'] != null) {
        _subscriptions.remove(err['path']);
      }

      if (err is NesError) {
        _disconnect(() => _nextTick(finalize)(err), true);
      }

      throw err;
    });

    return _ws!.stream.listen(
      (data) {
        try {
          // print('_connect _ws.stream.listen: ${data.toString()}');
          _onMessage(_Response(data));
        } catch (e) {
          print(e is _HapiError ? e.reason : e.toString());
        }
      },
      onError: (event) {
        // print('_connect _ws.stream.listen onError: ${event.toString()}');
        timeout?.cancel();
        if (_willReconnect()) {
          return reconnect(event);
        }

        _cleanup();
        final error = NesError('Socket error', ErrorTypes.WS);
        return finalize(error);
      },
      onDone: reconnect,
      cancelOnError: false,
    );
  }

  bool overrideReconnectionAuth(auth) {
    if (_reconnection == null) {
      return false;
    }
    Map<String, dynamic>? authMap;
    String? authString;
    final authParsed = json.decode(auth);
    if (authParsed is Map) {
      authMap = authParsed.cast<String, dynamic>();
    } else if (authParsed is String) {
      authString = authParsed;
    }

    _reconnection!.settings?.auth = _Auth(
      headers: authMap != null ? _Headers.fromMap(authMap) : null,
      token: authString,
    );
    return true;
  }

  Future reauthenticate(Map<String, dynamic> options) {
    overrideReconnectionAuth(options);

    final request = _Request(
      type: 'reauth',
      auth: _Auth.fromMap(options),
    );

    return _send(request, true);
  }

  Future disconnect() {
    return Future(() {
      return _disconnect(() {}, false);
    });
  }

  void _disconnect(Function next, bool isInternal) {
    _reconnection = null;
    _reconnectionTimer?.cancel();
    _reconnectionTimer = null;

    final bool requested = _disconnectRequested ?? isInternal;

    if (_disconnectListeners != null) {
      _disconnectRequested = requested;
      _disconnectListeners!.add(next);
      return;
    }

    if (_ws == null ||
        _ws!.innerWebSocket == null ||
        _ws!.innerWebSocket!.readyState != WebSocket.open ||
        _ws!.innerWebSocket!.readyState != WebSocket.connecting) {
      return next();
    }

    _disconnectRequested = requested;
    _disconnectListeners = [next];
    _ws!.sink.close();
  }

  _cleanup() {
    if (_ws != null) {
      IOWebSocketChannel ws = _ws!;
      _ws = null;

      if (ws.innerWebSocket!.readyState != WebSocket.closed &&
          ws.innerWebSocket!.readyState != WebSocket.closing) {
        ws.sink.close();
      }
    }

    _packets = [];
    id = null;

    _heartbeat!.cancel();
    _heartbeat = null;

    // Flush pending requests
    NesError error =
        NesError('Request failed - server disconnected', ErrorTypes.DISCONNECT);

    final requests = _requests;
    _requests.clear();
    final ids = requests.keys;

    for (var id in ids) {
      final request = requests[id];
      if (request != null) {
        request.timeout?.cancel();

        request.reject = (_) => Future.error(_!);
        request.reject!(error);
      }
    }

    if (_disconnectListeners != null) {
      final List<Function> listeners = _disconnectListeners!;
      _disconnectListeners = null;
      _disconnectRequested = false;
      for (Function element in listeners) {
        element();
      }
    }
  }

  _reconnect() {
    final reconnection = _reconnection;
    if (reconnection == null) {
      return;
    }

    if (reconnection.retries! < 1) {
      return _disconnect(_ignore, true);
    }

    reconnection.retries = reconnection.retries ?? 1;
    reconnection.retries = reconnection.retries! - 1;

    reconnection.wait = reconnection.wait ?? 0;
    reconnection.wait = reconnection.wait! + (reconnection.delay ?? 0);

    final timeout = math.min(reconnection.wait!, reconnection.maxDelay ?? 0);

    _reconnectionTimer = Timer(Duration(milliseconds: timeout), () {
      _connect(
        reconnection.settings != null
            ? _ConnectOptions.fromMap(reconnection.settings!.toMap())
            : _ConnectOptions(retries: double.infinity),
        false,
        (err) {
          if (err != null) {
            _onErrorController.add(err);
            return _reconnect();
          }
        },
      );
    });
  }

  Future request({
    required String path,
    String? method,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? payload,
  }) {
    final request = _Request(
      type: 'request',
      method: method ?? 'GET',
      path: path,
      headers: _Headers.fromMap(headers ?? {}),
      payload: _Payload.fromMap(payload ?? {}),
    );

    return _send(request, true);
  }

  Future message(String message) => _send(
      _Request(
        type: 'message',
        message: message,
      ),
      true);

  bool _isReady() {
    return _ws != null &&
        _ws!.innerWebSocket != null &&
        _ws!.innerWebSocket!.readyState == WebSocket.open;
  }

  Future _send(_Request request, bool track) {
    // print('_send request: ${request.toString()}');

    if (!_isReady()) {
      return Future.error(NesError(
          'Failed to send message - server disconnected',
          ErrorTypes.DISCONNECT));
    }

    _ids++;
    request.id = _ids.toString();
    String encoded;

    try {
      encoded = request.toString();
    } catch (e) {
      return Future.error(e);
    }

    if (!track) {
      try {
        // print('_send track - false : $encoded');
        _ws?.sink.add(encoded);
        return Future.value();
      } catch (e) {
        return Future.error(NesError(e.toString(), ErrorTypes.WS));
      }
    }

    _Record record = _Record();

    final future = Future(() {
      record.resolve = () => Future.value();
      record.reject = (err) => Future.error(err!);
    });

    Future timeoutHandler() {
      record.timeout = null;
      return record
          .reject!(NesError('Requested timed out', ErrorTypes.TIMEOUT));
    }

    if (_settings.timeout != null) {
      record.timeout =
          Timer(Duration(milliseconds: _settings.timeout!), timeoutHandler);
    }

    _requests[request.id!] = record;

    try {
      // print('_send encoded: $encoded');
      _ws?.sink.add(encoded);
    } catch (e) {
      _requests[request.id!]!.timeout?.cancel();
      _requests.remove(request.id!);
      return Future.error(NesError(e, ErrorTypes.WS));
    }

    return future;
  }

  Future _hello(_Auth? auth) {
    _Request request = _Request(
      type: 'hello',
      version: _version,
    );
    if (auth != null) {
      request.auth = auth;
    }

    final List<String> subs = subscriptions();
    if (subs.isNotEmpty) {
      request.subs = subs;
    }

    return _send(request, true);
  }

  List<String> subscriptions() {
    return _subscriptions.keys.toList();
  }

  Future subscribe(
    String path, [
    void Function(
      dynamic,
      Map<String, dynamic>? flags,
    )?
        handler,
  ]) {
    if (path[0] != '/') {
      return Future.error(NesError('Invalid path', ErrorTypes.USER));
    }

    final List? subs = _subscriptions[path];
    if (subs != null) {
      if (!subs.contains(handler)) {
        subs.add(handler);
      }
      return Future.value();
    }

    _subscriptions[path] = [handler];

    if (!_isReady()) {
      return Future.value();
    }

    final _Request request = _Request(type: 'sub', path: path);

    return _send(request, true).catchError((_) {
      _subscriptions.remove(path);
    });
  }

  Future unsubscribe(String path, Function? handler) {
    if (path[0] != '/') {
      return Future.error(NesError('Invalid path', ErrorTypes.USER));
    }

    final List? subs = _subscriptions[path];
    if (subs == null) {
      return Future.value();
    }

    bool _sync = false;
    if (handler == null) {
      _subscriptions.remove(path);
      _sync = true;
    } else {
      final int pos = subs.indexOf(handler);
      if (pos == -1) {
        return Future.value();
      }

      subs.sublist(pos, 1);
      if (subs.length == 0) {
        _subscriptions.remove(path);
        _sync = true;
      }
    }

    if (!_sync || !_isReady()) {
      return Future.value();
    }

    final _Request request = _Request(type: 'unsub', path: path);

    return _send(request, true).catchError(_ignore);
  }

  _onMessage(_Response msg) {
    _beat();
    String? data = msg.data;
    Map<String, dynamic> update;

    if (!data.startsWith('{')) {
      _packets.add(data.substring(1));
      if (!data.startsWith('!')) {
        return;
      }

      data = _packets.join('');
      _packets = [];
    }

    if (_packets.length == 1) {
      _packets = [];
      _onErrorController
          .add(NesError('Received an incomplete message', ErrorTypes.PROTOCOL));
    }

    try {
      update = json.decode(data);
    } catch (e) {
      return _onErrorController.add(NesError(e, ErrorTypes.PROTOCOL));
    }

    _HapiError? error;

    if (update['statusCode'] != null && update['statusCode'] >= 400) {
      // print('_onMessage statusCode ${update['statusCode']}');
      final String _msg_ = update['payload']['message'] != null
          ? update['payload']['error']
          : 'Error';
      error = _HapiError(
        reason: _msg_,
        type: ErrorTypes.SERVER,
        headers: _Headers.fromMap(update['headers'] ?? {}),
        path: update['path'] ?? '',
        payload: _ErrorPayload.fromMap(update['payload'] ?? {}),
        statusCode: update['statusCode'],
      );
    }

    // print('_onMessage type ${update['type']}');
    switch (update['type']) {
      case 'ping':
        return _send(_Request(type: 'ping'), false).catchError(_ignore);

      case 'update':
        return _onUpdateController.add(update['message']);

      case 'pub':
      case 'revoke':
        final handlers = _subscriptions[update['path']];
        if (update['type'] == 'revoke') {
          _subscriptions.remove(update['path']);
        }

        if (handlers != null && update['message'] != null) {
          Map<String, dynamic> flags = {};
          if (update['type'] == 'revoke') {
            flags['revoked'] = true;
          }

          for (var handler in handlers) {
            handler(update['message'], flags);
          }
        }

        return;
      default:
    }

    final _Record? request = _requests[update['id']];
    if (request == null) {
      return _onErrorController.add(NesError(
          'Received response for unknown request', ErrorTypes.PROTOCOL));
    }

    request.timeout?.cancel();
    _requests.remove(update['id']);

    Future next(_HapiError? err, [args]) {
      if (err != null) {
        // print('_onMessage next err: ${err.reason}');
        return Future.error(err);
      }
      return Future.value(args);
    }

    switch (update['type']) {
      // Response
      case 'request':
        return next(error, {
          'payload': update['payload'],
          'statusCode': update['statusCode'],
          'headers': update['headers'],
        });

      // Custom message
      case 'message':
        return next(error, {'payload': update['message']});

      // Authentication
      case 'hello':
        id = update['socket'];
        if (update['heartbeat'] != null) {
          _heartbeatTimeout =
              update['heartbeat']['interval'] + update['heartbeat']['timeout'];
          _beat();
        }

        return next(error);

      case 'reauth':
        return next(error, true);

      // Subscriptions
      case 'sub':
      case 'unsub':
        return next(error);

      default:
        break;
    }

    next(_HapiError(
      reason: 'Received invalid response',
      type: ErrorTypes.PROTOCOL,
    ));
    return _onErrorController.add(NesError(
      'Received unknown response type: ${update['type']}',
      ErrorTypes.PROTOCOL,
    ));
  }

  void _beat() {
    if (_ws == null || _heartbeatTimeout == null) {
      return;
    }

    _heartbeat?.cancel();

    _heartbeat = Timer(Duration(milliseconds: _heartbeatTimeout!), () {
      _onErrorController.add(NesError(
          'Disconnecting due to heartbeat timeout', ErrorTypes.TIMEOUT));
      _onHeartbeatTimeoutController.add(_willReconnect());
      _ws!.sink.close();
    });
  }

  bool _willReconnect() {
    return _reconnection != null && _reconnection!.retries! >= 1;
  }

  Stream<int?> status() async* {
    yield _ws?.innerWebSocket?.readyState;
  }

  IOWebSocketChannel? get channel => _ws;
}

class _Settings {
  _WS? ws;
  int? timeout;
  _Headers? headers;
  _Auth? auth;

  _Settings({
    this.ws,
    this.timeout,
    this.headers,
    this.auth,
  });

  factory _Settings.fromMap(Map<String, dynamic> _json) => _Settings(
        ws: _json['ws'] != null ? _WS.fromMap(_json['ws']) : null,
        timeout: _json['timeout'],
        auth: _json['auth'] != null ? _Auth.fromMap(_json['auth']) : null,
        headers: _json['headers'] == null
            ? null
            : _Headers.fromMap(_json['headers']),
      );
  factory _Settings.fromJson(String str) => _Settings.fromMap(json.decode(str));

  Map<String, dynamic> toMap() {
    final Map<String, dynamic> _settingsMap = {};
    if (ws != null) {
      _settingsMap['ws'] = ws;
    }
    if (auth != null) {
      _settingsMap['auth'] = auth;
    }
    if (timeout != null) {
      _settingsMap['timeout'] = timeout;
    }
    return _settingsMap;
  }

  String toJson() => json.encode(toMap());

  @override
  String toString() => toJson();
}

class _Auth {
  _Headers? headers;
  String? token;

  _Auth({this.headers, this.token});

  factory _Auth.fromJson(String str) {
    if (json.decode(str) is Map) {
      return _Auth.fromMap(json.decode(str));
    } else {
      return _Auth(token: str);
    }
  }
  factory _Auth.fromMap(Map<String, dynamic> _json) => _Auth(
        headers: _Headers.fromMap(_json['headers'] ?? {}),
      );

  Map<String, dynamic> toMap() {
    final Map<String, dynamic> _authMap = {};
    if (headers != null) {
      _authMap['headers'] = headers!.toMap();
    }
    return _authMap;
  }

  @override
  String toString() {
    if (headers != null) {
      return headers!.toJson();
    }
    return token!;
  }
}

class _WS {
  int? maxPayload;

  _WS({this.maxPayload});

  factory _WS.fromMap(Map<String, dynamic> _json) => _WS(
        maxPayload: _json['maxPayload'],
      );
  factory _WS.fromJson(String str) => _WS.fromMap(json.decode(str));

  Map<String, dynamic> toMap() {
    final Map<String, dynamic> _wsMap = {};
    if (maxPayload != null) {
      _wsMap['maxPayload'] = maxPayload;
    }
    return _wsMap;
  }

  String toJson() => json.encode(toMap());

  @override
  String toString() {
    return toJson();
  }
}

abstract class _Connect {
  int? timeout;
  int? delay;
  int? maxDelay;
  double? retries = double.infinity;
  bool? reconnect;
  _Auth? auth;

  _Connect({
    this.timeout,
    this.delay,
    this.maxDelay,
    this.retries,
    this.reconnect,
    this.auth,
  });

  Map<String, dynamic> toMap() {
    final Map<String, dynamic> _connectOptionsMap = {};
    if (timeout != null) {
      _connectOptionsMap['timeout'] = timeout;
    }
    if (delay != null) {
      _connectOptionsMap['delay'] = delay;
    }
    if (maxDelay != null) {
      _connectOptionsMap['maxDelay'] = maxDelay;
    }
    if (reconnect != null) {
      _connectOptionsMap['reconnect'] = reconnect;
    }
    if (retries != null) {
      _connectOptionsMap['retries'] = retries;
    }
    if (auth != null) {
      _connectOptionsMap['auth'] = auth!.toMap();
    }
    return _connectOptionsMap;
  }

  String toJson() => json.encode(toMap());

  @override
  String toString() => toJson();
}

class _ConnectOptions extends _Connect {
  _ConnectOptions({
    int? timeout,
    int? delay,
    int? maxDelay,
    double? retries,
    bool? reconnect,
    _Auth? auth,
  }) : super(
          timeout: timeout,
          delay: delay,
          maxDelay: maxDelay,
          retries: retries,
          reconnect: reconnect,
          auth: auth,
        );

  factory _ConnectOptions.fromMap(Map<String, dynamic> _json) =>
      _ConnectOptions(
        timeout: _json['timeout'],
        delay: _json['delay'],
        maxDelay: _json['maxDelay'],
        retries: _json['retries'],
        reconnect: _json['reconnect'],
        auth: _json['auth'] != null ? _Auth.fromMap(_json['auth']) : null,
      );
  factory _ConnectOptions.fromJson(String str) =>
      _ConnectOptions.fromMap(json.decode(str));
}

class _Reconnection extends _Connect {
  _Settings? settings;
  int? wait;

  _Reconnection({
    this.wait,
    int? delay,
    int? maxDelay,
    double? retries,
    bool? reconnect,
    this.settings,
  }) : super(
          timeout: wait,
          delay: delay,
          maxDelay: maxDelay,
          retries: retries,
          reconnect: reconnect,
        );
}

class _Request {
  String? id;
  String? version;
  String type;
  String? method = 'GET';
  String? path;
  String? message;
  _Payload? payload;
  _Headers? headers;
  _Auth? auth;
  List<String>? subs;

  _Request({
    required this.type,
    this.id,
    this.auth,
    this.method,
    this.message,
    this.headers,
    this.payload,
    this.version,
    this.subs,
    this.path,
  });

  factory _Request.fromMap(Map<String, dynamic> _json) => _Request(
        id: _json['id'],
        type: _json['type'],
        method: _json['method'],
        version: _json['version'],
        message: _json['message'],
        subs: _json['subs'],
        path: _json['path'],
        headers: _Headers.fromMap(_json['headers'] ?? {}),
        payload: _Payload.fromMap(_json['payload'] ?? {}),
        auth: _json['auth'] == null ? null : _Auth.fromMap(_json['auth']),
      );

  Map<String, dynamic> toMap() {
    final Map<String, dynamic> _requestMap = {'type': type};
    if (id != null) {
      _requestMap['id'] = id;
    }
    if (method != null) {
      _requestMap['method'] = method;
    }
    if (message != null) {
      _requestMap['message'] = message;
    }
    if (version != null) {
      _requestMap['version'] = version;
    }
    if (subs != null) {
      _requestMap['subs'] = subs;
    }
    if (path != null) {
      _requestMap['path'] = path;
    }
    if (headers != null) {
      print(headers);
      _requestMap['headers'] = headers?.toMap();
    }
    if (payload != null) {
      _requestMap['payload'] = payload?.toMap();
    }
    if (auth != null) {
      _requestMap['auth'] = auth?.toMap();
    }

    return _requestMap;
  }

  String toJson() => json.encode(toMap());

  @override
  String toString() => toJson();
}

class _Response {
  String data;

  _Response(this.data);
}

class _Payload {
  String? content;

  _Payload({this.content});

  factory _Payload.fromMap(Map<String, dynamic> _json) =>
      _Payload(content: _json['content']);

  Map<String, dynamic> toMap() {
    final Map<String, dynamic> _payloadMap = {};
    if (content != null) _payloadMap['content'] = content;
    return _payloadMap;
  }

  String toJson() => json.encode(content);

  @override
  String toString() => toJson();
}

class _HapiError {
  final String reason;
  final ErrorTypes type;
  final int? statusCode;
  final _ErrorPayload? payload;
  final _Headers? headers;
  final String? path;

  _HapiError({
    required this.reason,
    required this.type,
    this.statusCode,
    this.payload,
    this.headers,
    this.path,
  });
}

class _Headers {
  String? authorization;
  String? cookie;

  _Headers({this.authorization, this.cookie});

  factory _Headers.fromMap(Map<String, dynamic> _json) => _Headers(
        authorization: _json['authorization'] ?? _json['Authorization'],
        cookie: _json['cookie'] ?? _json['Cookie'],
      );

  factory _Headers.fromJson(String str) => _Headers.fromMap(json.decode(str));

  Map<String, dynamic> toMap() {
    final Map<String, dynamic> _headersMap = {};
    if (authorization != null) {
      _headersMap['authorization'] = authorization;
    }
    if (cookie != null) {
      _headersMap['cookie'] = cookie;
    }
    return _headersMap;
  }

  String toJson() => json.encode(toMap());

  @override
  String toString() => toJson();
}

class _ErrorPayload {
  String? message;
  String? error;

  _ErrorPayload({this.error, this.message});

  factory _ErrorPayload.fromMap(Map<String, dynamic> _json) => _ErrorPayload(
        message: _json['message'],
        error: _json['error'],
      );
}

class _Log {
  int? code;
  String? explanation;
  String? reason;
  bool? wasClean;
  bool? willReconnect;
  bool? wasRequested;

  _Log({
    this.code,
    this.explanation,
    this.reason,
    this.wasClean,
    this.willReconnect,
    this.wasRequested,
  });

  factory _Log.fromMap(Map<String, dynamic> _json) => _Log(
        code: _json['code'],
        explanation: _json['explanation'],
        reason: _json['reason'],
        wasClean: _json['wasClean'],
        willReconnect: _json['willReconnect'],
        wasRequested: _json['wasRequested'],
      );

  Map<String, dynamic> toMap() {
    final Map<String, dynamic> logMap = {};
    if (code != null) {
      logMap['code'] = code;
    }
    if (explanation != null) {
      logMap['explanation'] = explanation;
    }
    if (reason != null) {
      logMap['reason'] = reason;
    }
    if (wasClean != null) {
      logMap['wasClean'] = wasClean;
    }
    if (willReconnect != null) {
      logMap['willReconnect'] = willReconnect;
    }
    if (wasRequested != null) {
      logMap['wasRequested'] = wasRequested;
    }
    return logMap;
  }

  String toJson() => json.encode(toMap());

  @override
  String toString() => toJson();
}

class _Record {
  Future Function()? resolve;
  Future Function(NesError? error)? reject;
  Timer? timeout;

  _Record({
    this.resolve,
    this.reject,
    this.timeout,
  });
}
