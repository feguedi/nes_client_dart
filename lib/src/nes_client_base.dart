import 'client.dart';
// TODO: Put public facing types in this file.

class NesClient extends Client {
  final String _url;
  Map<String, dynamic>? settings;

  NesClient(this._url, {this.settings}) : super(_url, settings: settings);
}
