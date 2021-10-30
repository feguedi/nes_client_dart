import 'package:nes_client/nes_client.dart';

void main() async {
  try {
    // Subscription filter example
    // https://hapi.dev/module/nes/api?v=12.0.4#subscription-filter
    final NesClient nesClient = NesClient('ws://localhost:3003');
    await nesClient.connect(
      auth: {
        'headers': {'Authorization': 'Basic am9objpzZWNyZXQ='}
      },
    );

    final request = await nesClient.request(path: '/');
    print('request: $request');

    await nesClient.subscribe('/items', (update, flags) {
      print('update: ${update.toString()}');
      print('flags: ${flags.toString()}');
    });

    await nesClient.onUpdate.listen((event) {
      print('Server says $event');
    });
  } catch (e) {
    rethrow;
  }
}
