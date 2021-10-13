import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import './nes_error.dart';

class Client {
  final String _url;
  _Settings? _settings;

  int? _heartbeatTimeout;

  WebSocket? _ws;
  _Reconnection? _reconnection;
  Timer? _reconnectionTimer;
  int? _ids = 0;
  Map? _requests = {};
  Map<String, dynamic>? _subscriptions = {};
  Timer? _heartbeat;
  List? _packets = [];
  List<Function>? _disconnectListeners;
  bool? _disconnectRequested = false;
  int? id;
  int version = 2;

  Client(this._url, {Map<String, dynamic>? settings}) {
    _settings = _Settings.fromMap(settings ?? {});
    _settings!.maxPayload = _settings!.maxPayload ?? 0;
  }

  _ignore() {}

  String? stringify(Object? message) {
    try {
      return json.encode(message);
    } catch (e) {
      throw NesError(e, ErrorTypes.USER);
    }
  }

  nextTick(callback) {
    return (err) => {Future.delayed(Duration(seconds: 0), callback(err))};
  }

  // connect(Map<String, dynamic>? options) {
  connect({
    bool? reconnect,
    int? timeout,
    int? delay,
    int? maxDelay,
    double? retries,
    Map<String, String>? headers,
  }) {
    final _ConnectOptions _connectOptions = _ConnectOptions(
      reconnect: reconnect,
      timeout: timeout,
      delay: delay,
      maxDelay: maxDelay,
      retries: retries,
      headers: headers != null ? _Headers.fromMap(headers) : null,
    );
    if (_reconnection != null) {
      return Future.error(
        NesError('Cannot connect while client attempts to reconnect',
            ErrorTypes.USER),
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
          auth: _Auth(headers != null ? _Headers.fromMap(headers) : null),
        ),
      );
    } else {
      _reconnection = null;
    }

    return Future.microtask(() {
      _connect(_connectOptions, true, (err) {
        if (err) {
          return Future.error(err);
        }

        return Future.value();
      });
    });
  }

  onError(err) => print(err);
  onConnect() => _ignore();
  onDisconnect() => _ignore();
  onHeartbeatTimeout() => _ignore();
  onUpdate() => _ignore();

  void _connect(_ConnectOptions options, bool initial, Function? next) async {
    WebSocket ws = await WebSocket.connect(_url,
        protocols: _settings != null ? _settings!.protocols : null);
    _ws = ws;

    if (_reconnectionTimer != null) {
      _reconnectionTimer!.cancel();
      _reconnectionTimer = null;
    }

    finalize(NesError err) {
      if (next != null) {
        final nextHolder = next!;
        next = null;
        return nextHolder(err);
      }

      return onError(err);
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
  }

  reauthenticate(_Auth auth) {
    overrideReconnectionAuth(auth);

    final _SendRequest _request = _SendRequest(type: 'reauth', auth: auth);

    return _send(_request, true);
  }

  disconnect() {
    return Future.microtask(() {
      _disconnect(() {}, false);
    });
  }

  _disconnect(Function next, isInternal) {
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
        (_ws!.readyState != WebSocket.open &&
            _ws!.readyState != WebSocket.connecting)) {
      return next();
    }

    _disconnectRequested = requested;
    _disconnectListeners = [next];
    _ws!.close();
  }

  _cleanup() {
    if (_ws != null) {
      WebSocket ws = _ws!;
      _ws = null;

      if (ws.readyState != WebSocket.closed &&
          ws.readyState != WebSocket.closing) {
        ws.close();
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
    _requests = {};
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
      headers: reconnection.settings?.auth?.headers,
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

  bool _willReconnect() {
    return _reconnection != null && _reconnection!.retries >= 1;
  }

  request({Map<String, dynamic>? options, String? path}) {
    if (options == null && path != null) {
      options = {
        'method': 'GET',
        'path': path,
      };
    } else if (options == null && path == null) {
      return;
    }

    final _request = _SendRequest(
        type: 'request',
        method: options!['method'],
        path: options['path'],
        headers: options['headers'],
        payload: options['payload']);

    return _send(_request, true);
  }

  message() {}
  _isReady() {
    return _ws != null && _ws!.readyState == WebSocket.open;
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
      encoded = stringify(request)!;
    } catch (e) {
      return Future.error(e);
    }

    // Ignore errors
    if (!track) {
      try {
        _ws!.add(encoded);
        return Future.value();
      } catch (e) {
        return Future.error(e);
      }
    }

    final record = _Record();

    // Track errors
    if (_settings!.timeout != null) {
      record.timeout = Timer(Duration(seconds: _settings!.timeout ?? 5), () {
        record.timeout = null;
        return;
      });
    }

    try {
      _ws!.add(encoded);
    } catch (e) {
      _requests!.remove(request.id);
      return Future.error(NesError(e, ErrorTypes.WS));
    }

    return Future(() {});
  }

  _hello(auth) {
    final _request = _SendRequest(type: 'hello', version: version);

    if (auth != null) {
      _request.auth = auth;
    }

    final subs = subscriptions();
    if (subs.isNotEmpty) {
      _request.subs = subs;
    }

    return _send(_request, true);
  }

  List<String> subscriptions() {
    return _subscriptions != null ? _subscriptions!.keys.toList() : [];
  }

  subscribe(String? path, Function handler) {
    if (path == null || path[0] != '/') {
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

    final _SendRequest _request = _SendRequest(type: 'sub', path: path);

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

    final request = _SendRequest(type: 'unsub', path: path);
    final future = _send(request, true);
    future.catchError((e) => print(e));

    return future;
  }

  _onMessage(message) {
    _beat();

    final data = message.data;
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
      _ws!.close();
    });
  }

  bool overrideReconnectionAuth(_Auth auth) {
    if (_reconnection == null) {
      return false;
    }
    _reconnection!.settings!.auth = auth;
    return true;
  }
}

class _Reconnection {
  late int _wait;
  late int _delay;
  late int _maxDelay;
  late double _retries;
  _HeadersSettings? _settings;

  _Reconnection(
      {required int wait,
      required int delay,
      required int maxDelay,
      required double retries,
      _HeadersSettings? settings}) {
    _wait = wait;
    _delay = delay;
    _maxDelay = maxDelay;
    _retries = retries;
    _settings = settings;
  }

  int get wait => _wait;
  int get delay => _delay;
  int get maxDelay => _maxDelay;
  double get retries => _retries;
  _HeadersSettings? get settings => _settings;

  set wait(int newVal) {
    _wait = newVal;
  }

  set delay(int newVal) {
    _delay = newVal;
  }

  set maxDelay(int newVal) {
    _maxDelay = newVal;
  }

  set retries(double newVal) {
    _retries = newVal;
  }

  set settings(_HeadersSettings? newVal) {
    _settings = newVal;
  }
}

class _HeadersSettings {
  int? _timeout;
  _Auth? _auth;

  _HeadersSettings({int? timeout, _Auth? auth}) {
    _auth = auth;
    _timeout = timeout;
  }

  factory _HeadersSettings.fromJson(String str) =>
      _HeadersSettings.fromMap(json.decode(str));
  String toJson() => json.encode(toMap());

  factory _HeadersSettings.fromMap(Map<String, dynamic> json) =>
      _HeadersSettings(
        auth: _Auth.fromMap(json['auth']),
        timeout: json['timeout'],
      );
  Map<String, dynamic> toMap() => {
        'auth': _auth != null ? _auth!.toMap() : _auth,
        'timeout': _timeout,
      };

  int? get timeout => _timeout;
  _Auth? get auth => _auth;

  set timeout(int? newVal) {
    _timeout = newVal;
  }

  set auth(_Auth? newVal) {
    _auth = newVal;
  }
}

class _Auth {
  _Headers? _headers;
  _Auth(this._headers);

  factory _Auth.fromJson(String str) => _Auth.fromMap(json.decode(str));
  String toJson() => json.encode(toMap());

  factory _Auth.fromMap(Map<String, dynamic> json) =>
      _Auth(_Headers.fromMap(json['headers']));
  Map<String, dynamic> toMap() =>
      {'headers': _headers != null ? _headers!.toMap() : null};

  _Headers? get headers => _headers;
  set headers(_Headers? newVal) {
    _headers = newVal;
  }
}

class _Headers {
  String? _authorization;
  _Headers(this._authorization);

  factory _Headers.fromJson(String str) => _Headers.fromMap(json.decode(str));
  String toJson() => json.encode(toMap());

  factory _Headers.fromMap(Map<String, dynamic> json) =>
      _Headers(json['Authorization']);
  Map<String, dynamic> toMap() => {
        'Authorization': _authorization,
      };

  String? get authorization => _authorization;
  set authorization(String? newVal) {
    _authorization = newVal;
  }
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
  int? version;
  List<String>? subs;

  _SendRequest({
    required this.type,
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

  factory _SendRequest.fromMap(Map<String, dynamic> json) => _SendRequest(
        type: json['type'],
        id: json['id'],
        method: json['method'],
        auth: json['auth'],
        path: json['path'],
        headers: json['headers'],
        message: json['message'],
        payload: json['payload'],
        version: json['version'],
        subs: json['subs'],
      );

  String toJson() => json.encode(toMap());
  Map<String, dynamic> toMap() => {
        'type': type,
        'id': id,
        'method': method,
        'auth': auth,
        'path': path,
        'headers': headers,
        'message': message,
        'payload': payload,
        'version': version,
        'subs': subs,
      };
}

class _Record {
  Function? resolve;
  Function? reject;
  Timer? timeout;

  _Record({this.resolve, this.reject, this.timeout});
}

class _ConnectOptions {
  bool? reconnect;
  int? timeout;
  int? delay;
  int? maxDelay;
  double? retries;
  _Headers? headers;

  _ConnectOptions({
    this.reconnect,
    this.timeout,
    this.delay,
    this.maxDelay,
    this.retries,
    this.headers,
  });
}

class _Settings {
  int? maxPayload;
  Iterable<String>? protocols;
  int? timeout;

  _Settings({this.maxPayload, this.protocols, this.timeout});

  factory _Settings.fromMap(Map<String, dynamic> json) => _Settings(
        maxPayload: json['maxPayload'],
        timeout: json['timeout'],
        protocols: json['protocols'],
      );
  factory _Settings.fromJson(String str) => _Settings.fromMap(json.decode(str));

  Map<String, dynamic> toMap() => {
        'maxPayload': maxPayload,
        'protocols': protocols,
        'timeout': timeout,
      };
  String toJson() => json.encode(toMap());
}
