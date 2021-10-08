import 'package:nes_client/nes_client.dart';

void main() async {
  final NesClient nesClient = NesClient('ws://192.168.1.89:8000');
  await nesClient.connect({
    'settings': {
      'headers': {'Authorization': 'Bearer token'},
    }
  });
}
