import 'client.dart';
// TODO: Put public facing types in this file.

/// Checks if you are awesome. Spoiler: you are.
class Awesome {
  bool get isAwesome => true;
}

class NesClient extends Client {
  final String _url;
  NesClient(this._url, {Map<String, dynamic>? settings})
      : super(_url, settings: settings);
}
