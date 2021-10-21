import 'dart:async';
import 'dart:collection' show HashMap;
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:web_socket_channel/io.dart';

import './nes_error.dart';

class Client {
  final String _url;
  _Settings? _settings;

  int? _heartbeatTimeout;

  IOWebSocketChannel? _ws;
  _Reconnection? _reconnection;
  Timer? _reconnectionTimer;
  int? _ids = 0;
  HashMap<String, dynamic>? _requests = HashMap.from({});
  HashMap<String, dynamic>? _subscriptions = HashMap.from({});
  Timer? _heartbeat;
  List? _packets = [];
  List<Function>? _disconnectListeners;
  bool? _disconnectRequested = false;
  int? id;
  String version = '2';

  Client(this._url, {Map<String, dynamic>? settings}) {
    _settings = _Settings.fromMap(settings ?? {});
    _settings?.maxPayload = _settings?.maxPayload ?? 0;
  }

  _ignore() {}

  onError(err) => print(err);
  onConnect() => _ignore();
  onDisconnect([_]) => _ignore();
  onHeartbeatTimeout() => _ignore();
  onUpdate([_]) => _ignore();

  String? _stringify(Object? message) {
    try {
      return json.encode(message);
    } catch (e) {
      throw NesError(e, ErrorTypes.USER);
    }
  }

  nextTick(callback) {
    return (err) => Future.delayed(Duration(seconds: 0), callback(err));
  }

  Future connect({
    bool? reconnect,
    int? timeout,
    int? delay,
    int? maxDelay,
    double? retries,
    Map<String, Map<String, String>>? auth,
  }) async {
    final Map<String, String>? _headers = auth != null &&
            auth.containsKey('headers') &&
            (auth['headers']!.containsKey('authorization') ||
                auth['headers']!.containsKey('Authorization') ||
                auth['headers']!.containsKey('cookie') ||
                auth['headers']!.containsKey('Cookie'))
        ? auth['headers']
        : null;
    final _ConnectOptions _connectOptions = _ConnectOptions(
      reconnect: reconnect,
      timeout: timeout,
      delay: delay,
      maxDelay: maxDelay,
      retries: retries,
      auth: _headers != null
          ? _Auth.fromMap({
              'headers': {
                'authorization': _headers.containsKey('authorization')
                    ? _headers['authorization']
                    : _headers.containsKey('Authorization')
                        ? _headers['Authorization']
                        : null,
                'cookie': _headers.containsKey('cookie')
                    ? _headers['cookie']
                    : _headers.containsKey('Cookie')
                        ? _headers['Cookie']
                        : null,
              },
            })
          : null,
    );

    if (_reconnection != null) {
      return Future.error(
        NesError(
          'Cannot connect while client attempts to reconnect',
          ErrorTypes.USER,
        ),
      );
    }

    if (_ws != null) {
      return Future.error(NesError('Already connected', ErrorTypes.USER));
    }

    if (reconnect != false) {
      _reconnection = _Reconnection(
        wait: 0,
        delay: delay ?? 1000,
        maxDelay: maxDelay ?? 5000,
        retries: retries ?? double.infinity,
        settings: _HeadersSettings(
          timeout: timeout,
          auth: _headers != null
              ? _Auth.fromMap({
                  'headers': {
                    'authorization': _headers.containsKey('authorization')
                        ? _headers['authorization']
                        : _headers.containsKey('Authorization')
                            ? _headers['Authorization']
                            : null,
                    'cookie': _headers.containsKey('cookie')
                        ? _headers['cookie']
                        : _headers.containsKey('Cookie')
                            ? _headers['Cookie']
                            : null,
                  },
                })
              : null,
        ),
      );
    } else {
      _reconnection = null;
    }

    return Future.microtask(() {
      _connect(_connectOptions, true, (err) {
        if (err != null) {
          return Future.error(err);
        }

        return Future.value();
      });
    });
  }

  void _connect(_ConnectOptions options, bool initial, Function? next) async {
    _ws = IOWebSocketChannel.connect(
      Uri.parse(_url),
      protocols: _settings?.protocols,
      headers: options.auth?.headers?.toMap(),
    );

    finalize(NesError? err) {
      if (next != null) {
        final nextHolder = next!;
        next = null;
        return nextHolder(err);
      }
    }

    reconnect(_Event event) {
      if (_ws!.innerWebSocket?.readyState == WebSocket.open) {
        finalize(NesError(
            'Connection terminated while waiting to connect', ErrorTypes.WS));
      }

      final wasRequested = _disconnectRequested;

      _cleanup();

      onDisconnect([event.willReconnect, event]);
      _reconnect();
    }

    timeoutHandler() {
      _cleanup();
      finalize(NesError('Connection timed out', ErrorTypes.TIMEOUT));

      if (initial) {
        return _reconnect();
      }
    }

    final Timer? timeout = options.timeout != null
        ? Timer(Duration(seconds: options.timeout!), timeoutHandler)
        : null;

    if (_reconnectionTimer != null) {
      _reconnectionTimer!.cancel();
      _reconnectionTimer = null;
    }

    _ws!.stream.listen((event) async {
      try {
        _reconnectionTimer?.cancel();
        final _helloResponse = await _hello(options.auth);
        onConnect();
        finalize(null);
      } catch (err) {
        final Map<String, dynamic>? mapErr = json.decode(err.toString());
        if (mapErr != null && mapErr.containsKey('path')) {
          _subscriptions?.remove(mapErr['path']);
        }

        _disconnect(() => nextTick(finalize)(err), true);
      }
      _onMessage(_Message.fromJson(event));
    });
  }

  bool overrideReconnectionAuth(_Auth auth) {
    if (_reconnection == null && _reconnection!.settings == null) {
      return false;
    }
    _reconnection!.settings!.auth = auth;
    return true;
  }

  reauthenticate(_Auth auth) {
    overrideReconnectionAuth(auth);

    final _SendRequest _request = _SendRequest('reauth', auth: auth);

    return _send(_request, true);
  }

  disconnect() {
    return Future.microtask(() {
      _disconnect(() {}, false);
    });
  }

  Future _disconnect(Function next, isInternal) async {
    _reconnection = null;
    _reconnectionTimer!.cancel();
    _reconnectionTimer = null;
    final requested = _disconnectRequested! || !isInternal;

    if (_disconnectListeners != null) {
      _disconnectRequested = requested;
      _disconnectListeners!.add(next);
      return;
    }

    if (_ws == null ||
        (_ws!.innerWebSocket?.readyState != WebSocket.open &&
            _ws!.innerWebSocket?.readyState != WebSocket.connecting)) {
      return next();
    }

    _disconnectRequested = requested;
    _disconnectListeners = [next];
    await _ws!.sink.close();
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
    _requests!.clear();
    final ids = requests!.keys;

    for (var id in ids) {
      final request = requests[id];
      request['timeout'].cancel();
      request['reject'](error);
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

    final _connectOptions = _ConnectOptions(
      reconnect: true,
      timeout: reconnection.settings?.timeout,
      delay: reconnection.delay,
      maxDelay: reconnection.maxDelay,
      retries: reconnection.retries,
      auth: reconnection.settings?.auth,
    );

    if (reconnection.retries < 1) {
      return _disconnect(_ignore, true);
    }

    reconnection.retries--;
    reconnection.wait = reconnection.wait + reconnection.delay;

    final timeout = math.min(reconnection.wait, reconnection.maxDelay);

    _reconnectionTimer = Timer(Duration(seconds: timeout), () {
      _connect(_connectOptions, false, (err) {
        if (err) {
          onError(err);
          return _reconnect();
        }
      });
    });
  }

  Future request({Map<String, dynamic>? options, String? path}) async {
    if (options == null && path != null) {
      options = {
        'method': 'GET',
        'path': path,
      };
    } else if (options == null && path == null) {
      return;
    }

    final _request = _SendRequest('request',
        method: options!['method'],
        path: options['path'],
        headers: options['headers'],
        payload: options['payload']);

    return await _send(_request, true);
  }

  bool _isReady() {
    return _ws != null && _ws!.innerWebSocket?.readyState == WebSocket.open;
  }

  Future _send(_SendRequest request, bool track) {
    if (!_isReady()) {
      return Future.error(NesError(
          'Failed to send message - server disconnected',
          ErrorTypes.DISCONNECT));
    }

    _ids = _ids! + 1;
    request.id = _ids;
    String encoded;

    try {
      encoded = json.encode(request.toMap());
    } catch (e) {
      return Future.error(e);
    }

    // Ignore errors
    if (!track) {
      try {
        return Future(() {
          _ws!.sink.add(encoded);
        });
      } catch (e) {
        return Future.error(e);
      }
    }

    final record = _Request(
      reject: (NesError reason) {
        return Future.error(reason);
      },
      resolve: (value) {
        return Future.value(value);
      },
    );

    // Track errors
    if (_settings!.timeout != null) {
      record.timeout = Timer(Duration(seconds: _settings!.timeout ?? 5), () {
        record.timeout = null;
        return record
            .reject!(NesError('Request timed out', ErrorTypes.TIMEOUT));
      });
    }

    _requests![request.id.toString()] = record;

    try {
      return Future(() {
        _ws!.sink.add(encoded);
      });
    } catch (e) {
      _requests![request.id.toString()].timeout?.cancel();
      _requests!.remove(request.id.toString());
      return Future.error(NesError(e, ErrorTypes.WS));
    }
  }

  Future _hello(_Auth? auth) async {
    final _request = _SendRequest('hello', version: version);

    if (auth != null) {
      _request.auth = auth;
    }

    final subs = subscriptions();
    if (subs.isNotEmpty) {
      _request.subs = subs;
    }

    final _sendResponse = await _send(_request, true);
    return _sendResponse;
  }

  List<String> subscriptions() {
    return _subscriptions != null ? _subscriptions!.keys.toList() : [];
  }

  Future subscribe(String path, Function? handler) async {
    if (path[0] != '/') {
      return Future.error(NesError('Invalid path', ErrorTypes.USER));
    }

    final List? subs = _subscriptions![path];
    if (subs != null) {
      // Already subscribed
      if (!subs.contains(handler)) {
        subs.add(handler);
      }
      return;
    }

    _subscriptions![path] = [handler];

    if (!_isReady()) {
      // Queued subscription
      return;
    }

    final _SendRequest _request = _SendRequest('sub', path: path);

    final future = _send(_request, true);

    future.catchError((ignoreError) {
      _subscriptions!.remove(path);
    });

    return future;
  }

  Future unsubscribe(String? path, Function? handler) {
    if (path == null || path[0] != '/') {
      return Future.error(NesError('Invalid path', ErrorTypes.USER));
    }

    List? subs = _subscriptions![path];
    if (subs == null) {
      return Future.value();
    }

    bool _sync = false;
    if (handler == null) {
      _subscriptions!.remove(path);
      _sync = true;
    } else {
      final int pos = subs.indexOf(handler);
      if (pos == -1) {
        return Future.value();
      }

      subs.removeAt(pos);
      if (subs.isEmpty) {
        _subscriptions!.remove(path);
        _sync = true;
      }
    }

    final request = _SendRequest('unsub', path: path);
    final future = _send(request, true);
    future.catchError((e) => print(e));

    return future;
  }

  message(String msg) async {
    try {
      final _SendRequest request = _SendRequest('message', message: msg);

      final _sendResponse = await _send(request, true);
      return _sendResponse;
    } on JsonUnsupportedObjectError {
      throw JsonUnsupportedObjectError('The map passed can\'t be serialized');
    } catch (e) {
      rethrow;
    }
  }

  _onMessage(_Message message) {
    _beat();

    _UpdateData? update;
    String data = message.data;
    Map<String, dynamic> mapData = json.decode(data);
    final String prefix = data[0];

    if (prefix != '{' && _packets != null) {
      _packets!.add(data.substring(1));
      if (prefix != '!') {
        return;
      }

      data = _packets!.join('');
      _packets = [];
    } else if (mapData.containsKey('statusCode') &&
        mapData['statusCode'] >= 400) {
      return onError(
          NesError(mapData['payload']['message'], ErrorTypes.PROTOCOL));
    }

    if (_packets!.isNotEmpty) {
      onError(NesError('Received an incomplete message', ErrorTypes.PROTOCOL));
    }

    try {
      update = _UpdateData.fromJson(data);
    } catch (e) {
      return onError(NesError(e, ErrorTypes.PROTOCOL));
    }

    // Recreate error

    NesError? error;

    if (update.statusCode != null && update.statusCode! >= 400) {
      error = update.payload != null &&
              (update.payload!.message != null || update.payload!.error != null)
          ? NesError(update.payload!.message ?? update.payload!.error,
              ErrorTypes.SERVER)
          : NesError('Error', ErrorTypes.SERVER);
    }

    // Ping

    if (update.type == 'ping') {
      return _send(_SendRequest('ping'), false).catchError(_ignore);
    }

    // Broadcast and update

    if (update.type == 'update') {
      return onUpdate(update.message);
    }

    // Publish or revoke

    if ((update.type == 'pub' || update.type == 'revoke') &&
        update.path != null) {
      final List<Function>? handlers =
          update.path == null ? null : _subscriptions![update.path ?? ''];
      if (update.type == 'revoke') {
        _subscriptions!.remove(update.path);
      }

      if (handlers != null && update.message != null) {
        final Map<String, dynamic> flags = {};
        if (update.type == 'revoke') {
          flags['revoked'] = true;
        }

        for (Function handler in handlers) {
          handler(update.message, flags);
        }
      }

      return;
    }

    // Lookup request (message must include an id from this point)

    final _Request? request = _requests![update.id];
    if (request == null) {
      return onError(NesError(
          'Received response for unknown request', ErrorTypes.PROTOCOL));
    }

    if (request.timeout != null) {
      request.timeout!.cancel();
    }
    _requests!.remove(update.id);

    next(err, args) {
      if (err != null) {
        return request.reject!(err);
      }
    }
  }

  _beat() {
    if (_heartbeatTimeout == null) {
      return;
    }

    _heartbeat!.cancel();
    _heartbeat = Timer(Duration(seconds: _heartbeatTimeout!), () {
      onError(NesError(
          'Disconnecting due to heartbeat timeout', ErrorTypes.TIMEOUT));
      onHeartbeatTimeout();
      _ws!.sink.close();
    });
  }
}

class _Reconnection {
  int wait;
  final int delay;
  final int maxDelay;
  double retries;
  _HeadersSettings? settings;

  _Reconnection({
    required this.wait,
    required this.delay,
    required this.maxDelay,
    required this.retries,
    _HeadersSettings? settings,
  });
}

class _HeadersSettings {
  int? timeout;
  _Auth? auth;

  _HeadersSettings({this.timeout, this.auth});

  factory _HeadersSettings.fromJson(String str) =>
      _HeadersSettings.fromMap(json.decode(str));
  String toJson() => json.encode(toMap());

  factory _HeadersSettings.fromMap(Map<String, dynamic> _json) =>
      _HeadersSettings(
        auth: _Auth.fromMap(_json['auth']),
        timeout: _json['timeout'],
      );
  Map<String, dynamic> toMap() => {
        'auth': auth != null ? auth!.toMap() : auth,
        'timeout': timeout,
      };
}

class _Auth {
  _Headers? headers;
  _Auth(this.headers);

  factory _Auth.fromJson(String str) => _Auth.fromMap(json.decode(str));
  String toJson() => json.encode(toMap());

  factory _Auth.fromMap(Map<String, dynamic> _json) => _Auth(
      _Headers.fromMap(_json.containsKey('headers') ? _json['headers'] : {}));
  Map<String, dynamic> toMap() => {
        'headers': headers != null ? headers!.toMap() : null,
      };

  @override
  String toString() => toJson();
}

class _Headers {
  String? cookie;
  String? authorization;
  _Headers({this.authorization, this.cookie});

  factory _Headers.fromJson(String str) => _Headers.fromMap(json.decode(str));
  String toJson() => json.encode(toMap());

  factory _Headers.fromMap(Map<String, dynamic> _json) => _Headers(
        authorization: _json.containsKey('authorization')
            ? _json['authorization']
            : _json.containsKey('Authorization')
                ? _json['Authorization']
                : null,
        cookie: _json.containsKey('cookie')
            ? _json['cookie']
            : _json.containsKey('Cookie')
                ? _json['Cookie']
                : null,
      );
  Map<String, dynamic> toMap() {
    Map<String, dynamic> _headersMap = {};
    if (authorization != null) {
      _headersMap['authorization'] = authorization;
    }
    if (cookie != null) {
      _headersMap['cookie'] = cookie;
    }
    return _headersMap;
  }

  @override
  String toString() => toJson();
}

class _SendRequest {
  int? id;
  String type;
  String? method = 'GET';
  _Auth? auth;
  String? path;
  _Headers? headers;
  String? message;
  String? payload;
  String? version;
  List<String>? subs;

  _SendRequest(
    this.type, {
    this.method,
    this.path,
    this.id,
    this.headers,
    this.payload,
    this.message,
    this.auth,
    this.subs,
    this.version,
  });

  @override
  String toString() => toJson();

  factory _SendRequest.fromJson(String str) =>
      _SendRequest.fromMap(json.decode(str));

  factory _SendRequest.fromMap(Map<String, dynamic> _json) => _SendRequest(
        _json['type'],
        id: _json['id'],
        method: _json['method'],
        auth: _json['auth'],
        path: _json['path'],
        headers: _json['headers'],
        message: _json['message'],
        payload: _json['payload'],
        version: _json['version'],
        subs: _json['subs'],
      );

  String toJson() => json.encode(toMap());
  Map<String, dynamic> toMap() {
    final Map<String, dynamic> _mapSendRequest = {
      'type': type,
    };
    if (id != null) {
      _mapSendRequest['id'] = id;
    }
    if (auth != null) {
      _mapSendRequest['auth'] = auth!.toMap();
    }
    if (method != null) {
      _mapSendRequest['method'] = method;
    }
    if (path != null) {
      _mapSendRequest['path'] = path;
    }
    if (headers != null) {
      _mapSendRequest['headers'] = headers!.toMap();
    }
    if (message != null) {
      _mapSendRequest['message'] = message;
    }
    if (payload != null) {
      _mapSendRequest['payload'] = payload;
    }
    if (version != null) {
      _mapSendRequest['version'] = version;
    }
    if (subs != null) {
      _mapSendRequest['subs'] = subs;
    }
    return _mapSendRequest;
  }
}

class _Request {
  Function? resolve;
  Function? reject;
  Timer? timeout;

  _Request({this.resolve, this.reject, this.timeout});
}

class _ConnectOptions {
  bool? reconnect;
  int? timeout;
  int? delay;
  int? maxDelay;
  double? retries;
  _Auth? auth;

  _ConnectOptions({
    this.reconnect,
    this.timeout,
    this.delay,
    this.maxDelay,
    this.retries,
    this.auth,
  });

  factory _ConnectOptions.fromMap(Map<String, dynamic> _json) =>
      _ConnectOptions(
        reconnect: _json['reconnect'],
        timeout: _json['timeout'],
        delay: _json['delay'],
        maxDelay: _json['maxDelay'],
        retries: _json['retries'],
        auth: _Auth.fromJson(_json['auth']),
      );

  factory _ConnectOptions.fromJson(String str) =>
      _ConnectOptions.fromMap(json.decode(str));

  Map<String, dynamic> toMap() => {
        'reconnect': reconnect,
        'timeout': timeout,
        'delay': delay,
        'maxDelay': maxDelay,
        'retries': retries,
        'auth': auth?.toMap(),
      };

  String toJson() => json.encode(toMap());
}

class _Settings {
  int? maxPayload;
  Iterable<String>? protocols;
  int? timeout;
  _Headers? headers;

  _Settings({this.maxPayload, this.protocols, this.timeout, this.headers});

  factory _Settings.fromMap(Map<String, dynamic> json) => _Settings(
        maxPayload: json['maxPayload'],
        timeout: json['timeout'],
        protocols: json['protocols'],
        headers:
            json['headers'] != null ? _Headers.fromJson(json['headers']) : null,
      );
  factory _Settings.fromJson(String str) => _Settings.fromMap(json.decode(str));

  Map<String, dynamic> toMap() => {
        'maxPayload': maxPayload,
        'protocols': protocols,
        'timeout': timeout,
        'headers': headers == null ? {} : headers!.toMap(),
      };
  String toJson() => json.encode(toMap());
}

class _Message {
  final String data;

  _Message(this.data);

  factory _Message.fromJson(String str) => _Message(str);

  Map<String, dynamic> toMap() => {'data': data};
  String toJson() => json.encode(toMap());

  @override
  String toString() => toJson();
}

class _UpdateData {
  String type;
  String? id;
  String? path;
  _Payload? payload;
  int? statusCode;
  String? socket;
  _Headers? headers;
  String? message;
  _HeartbeatTimes? heartbeat;

  _UpdateData({
    required this.type,
    this.id,
    this.path,
    this.statusCode,
    this.payload,
    this.socket,
    this.headers,
    this.message,
    this.heartbeat,
  });

  factory _UpdateData.fromMap(Map<String, dynamic> _json) => _UpdateData(
        type: _json['type'],
        id: _json['id'],
        path: _json['path'],
        statusCode: _json['statusCode'],
        payload: _json['payload'],
        socket: _json['socket'],
        headers: _json['headers'],
        message: _json['message'],
        heartbeat: _json['heartbeat'],
        // type: _json['type'],
      );
  factory _UpdateData.fromJson(String str) =>
      _UpdateData.fromMap(json.decode(str));

  Map<String, dynamic> toMap() => {
        'type': type,
        'id': id,
        'path': path,
        'statusCode': statusCode,
        'payload': payload,
        'socket': socket,
        'headers': headers,
        'message': message,
        'heartbeat': heartbeat,
      };
  String toJson() => json.encode(toMap());
}

class _ErrorMessage {
  final String type;
  final int? id;
  final String? statusCode;
  final _Payload? payload;

  _ErrorMessage(this.type, {this.id, this.statusCode, this.payload});

  factory _ErrorMessage.fromMap(Map<String, dynamic> _json) => _ErrorMessage(
        _json['type'],
        id: _json['id'],
        statusCode: _json['statusCode'],
        payload: _Payload.fromJson(_json['payload']),
      );
  factory _ErrorMessage.fromJson(String str) =>
      _ErrorMessage.fromMap(json.decode(str));

  Map<String, dynamic> toMap() {
    final Map<String, dynamic> _errorMessageMap = {'type': type};
    if (id != null) {
      _errorMessageMap['id'] = id;
    }
    if (statusCode != null) {
      _errorMessageMap['statusCode'] = statusCode;
    }
    if (payload != null) {
      _errorMessageMap['payload'] = payload!.toMap();
    }

    return _errorMessageMap;
  }

  String toJson() => json.encode(toMap());

  @override
  String toString() {
    return toJson();
  }
}

class _Payload {
  String? message;
  String? error;

  _Payload({this.message, this.error});

  factory _Payload.fromMap(Map<String, dynamic> json) => _Payload(
        message: json['message'],
        error: json['error'],
      );
  factory _Payload.fromJson(String str) => _Payload.fromMap(json.decode(str));

  Map<String, dynamic> toMap() => {
        'message': message,
        'error': error,
      };

  String toJson() => json.encode(toMap());
}

class _HeartbeatTimes {
  int? timeout;
  int? interval;
  _HeartbeatTimes({this.timeout, this.interval});
}

class _Event {
  final int? code;
  final String? explanation;
  final String? reason;
  final bool? wasClean;
  final bool? willReconnect;
  final bool? wasRequested;

  _Event({
    this.code,
    this.explanation,
    this.reason,
    this.wasClean,
    this.willReconnect,
    this.wasRequested,
  });

  factory _Event.fromMap(Map<String, dynamic> _json) => _Event(
        code: _json['code'],
        explanation: _json['explanation'],
        reason: _json['reason'],
        wasClean: _json['wasClean'],
        willReconnect: _json['willReconnect'],
        wasRequested: _json['wasRequested'],
      );

  factory _Event.fromJson(String str) =>
      _Event.fromMap(Map<String, dynamic>.from(json.decode(str)));

  Map<String, dynamic> toMap() => {
        'code': code,
        'explanation': explanation,
        'reason': reason,
        'wasClean': wasClean,
        'willReconnect': willReconnect,
        'wasRequested': wasRequested,
      };

  String toJson() => json.encode(toMap());
}
