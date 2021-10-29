import 'package:test/test.dart';
import 'package:nes_client/nes_client.dart';

void main() {
  group('Authentication tests', () {
    final String password = 'some_not_random_password_that_is_also_long_enough';
    final String basicAuth = 'Basic am9objpzZWNyZXQ=';

    setUp(() {
      // Additional setup goes here.
    });

    group('cookie', () {
      late NesClient nesClient;

      RegExp headerMatch = RegExp('source');
      String cookie = 'nes=';

      setUp(() {
        nesClient = NesClient(
          'ws://localhost:3003',
          {
            'ws': {
              'headers': {'cookie': '${cookie[1]}'},
            },
          },
        );
      });

      test('protects an endpoint', () {
        expect(nesClient, equals(2));
      });
    });
  });
}
