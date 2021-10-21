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

    print('connected');

    await nesClient.subscribe('/items', (update, flags) {
      print('update: ${update.toString()}');
      print('flags: ${flags.toString()}');
    });
  } catch (e) {
    rethrow;
  }
}
