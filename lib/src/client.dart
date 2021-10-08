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
  int? _reconnectionTimer;
  int? _ids = 0;
  Map? _requests = {};
  Map? _subscriptions = {};
  int? _heartbeat;
  List? _packets = [];
  bool? _disconnectListeners;
  bool? _disconnectRequested = false;

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
        settings: options['auth'] != null && options['timeout'] != null
            ? _Settings(
                timeout: options['timeout'],
                auth: _Auth(options['auth']['headers']))
            : null,
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
    WebSocket ws = await WebSocket.connect(_url);
    _ws = ws;
  }

  reauthenticate() {}
  disconnect() {}
  _disconnect(Function next, isInternal) {
    _reconnection = null;
    _reconnectionTimer = null;
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

    reconnection.retries -= 1;
    reconnection.wait = reconnection.wait + reconnection.delay;

    final timeout = Math.min(reconnection.wait, reconnection.maxDelay);

    // _reconnectionTimer = Future.delayed(Duration(milliseconds: timeout), () => {
    //   _connect(reconnection.settings!.toMap(), false, (err) => {

    //   })
    // }) as int?;
  }

  request() {}
  message() {}
  _isReady() {}
  _send() {}
  _hello() {}
  subscriptions() {}
  subscribe() {}
  unsubscribe() {}
  _onMessage() {}
  _beat() {}
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
