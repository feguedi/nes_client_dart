import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as Math;

import './nes_error.dart';

class Client {
  final String _url;
  Map? _settings;

  bool _heartbeatTimeout = false;

  WebSocket? _ws;
  _Reconnection? _reconnection;
  Timer? _reconnectionTimer;
  int? _ids = 0;
  Map? _requests = {};
  Map<String, dynamic>? _subscriptions = {};
  int? _heartbeat;
  List? _packets = [];
  List? _disconnectListeners;
  bool? _disconnectRequested = false;
  int version = 2;

  Client(this._url, {Map<String, dynamic>? settings}) {
    _settings = settings;
    _settings ??= {};
    _settings!['ws'] = _settings!['ws'] ?? {};
    _settings!['ws']['maxPayload'] = _settings!['ws']['maxPayload'] ?? 0;
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

  connect(Map<String, dynamic>? options) {
    options ??= {};
    if (_reconnection != null) {
      return Future.error(
        NesError('Cannot connect while client attempts to reconnect',
            ErrorTypes.USER),
      );
    }

    if (_ws != null) {
      return Future.error(NesError('Already connected', ErrorTypes.USER));
    }

    if (options['reconnect'] != false) {
      _reconnection = _Reconnection(
        wait: 0,
        delay: options['delay'] ?? 1000,
        maxDelay: options['maxDelay'] ?? 5000,
        retries: options['retries'] ?? double.infinity,
        settings: _Settings(
          timeout: options['timeout'],
          auth: _Auth(options['auth']['headers']),
        ),
      );
    } else {
      _reconnection = null;
    }

    return Future(() => {
          _connect(
              options!,
              true,
              (err) => {
                    if (err) {Future.error(err)}
                  })
        });
  }

  onError(err) => print(err);
  onConnect() => _ignore();
  onDisconnect() => _ignore();
  onHeartbeatTimeout() => _ignore();
  onUpdate() => _ignore();

  _connect(Map<String, dynamic> options, bool initial, next) async {
    WebSocket ws = await WebSocket.connect(_url,
        protocols: _settings != null ? _settings!['ws'] : null);
    _ws = ws;
  }

  reauthenticate(auth) {
    overrideReconnectionAuth(auth);

    final _SendRequest _request = _SendRequest(type: 'reauth', auth: auth);

    return _send(_request, true);
  }

  disconnect() {}
  _disconnect(Function next, isInternal) {
    _reconnection = null;
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

  _cleanup() {}
  _reconnect() {
    final reconnection = _reconnection;
    if (reconnection == null) {
      return;
    }

    if (reconnection.retries < 1) {
      return _disconnect(_ignore, true);
    }

    reconnection.retries--;
    reconnection.wait = reconnection.wait + reconnection.delay;

    final timeout = Math.min(reconnection.wait, reconnection.maxDelay);

    // _reconnectionTimer = Future.delayed(Duration(milliseconds: timeout), () => {
    //   _connect(reconnection.settings!.toMap(), false, (err) => {

    //   })
    // }) as int?;
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
        return Future(() => {});
      } catch (e) {
        return Future.error(e);
      }
    }

    // Track errors
    return Future(() => {});
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
  }

  unsubscribe() {}
  _onMessage(message) {
    _beat();

    final data = message.data;
  }

  _beat() {}

  overrideReconnectionAuth(auth) {
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
  _Settings? _settings;

  _Reconnection(
      {required int wait,
      required int delay,
      required int maxDelay,
      required double retries,
      _Settings? settings}) {
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
  _Settings? get settings => _settings;

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

  set settings(_Settings? newVal) {
    _settings = newVal;
  }
}

class _Settings {
  int? _timeout;
  _Auth? _auth;

  _Settings({int? timeout, _Auth? auth}) {
    _auth = auth;
    _timeout = timeout;
  }

  factory _Settings.fromJson(String str) => _Settings.fromMap(json.decode(str));
  String toJson() => json.encode(toMap());

  factory _Settings.fromMap(Map<String, dynamic> json) => _Settings(
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
