import 'package:nes_client/nes_client.dart';

void main() async {
  try {
    final NesClient nesClient = NesClient('ws://192.168.1.89:3000');
    await nesClient.connect(headers: {'Authorization': 'Bearer token'});

    print('connected');

    await nesClient.subscribe('/timeline/updates', (item) {
      print('item: ${item.toString()}');
    });
  } catch (e) {
    rethrow;
  }
}
