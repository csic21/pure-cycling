import 'dart:convert';
import 'package:cycling_app/core/sync/cloud_data_wipe_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test(
    'requires affirmative server verification, not merely HTTP success',
    () async {
      for (final body in <Map<String, Object?>>[
        {},
        {'wiped': false},
        {'deleted': true},
      ]) {
        final client = CloudDataWipeClient(
          endpoint: 'https://test.invalid/wipe-cloud-data',
          accessToken: () => 'fixture-token',
          httpClient: MockClient(
            (_) async => http.Response(jsonEncode(body), 200),
          ),
        );
        await expectLater(
          client.wipe(),
          throwsA(isA<CloudDataWipeException>()),
        );
        client.close();
      }
    },
  );

  test(
    'uses the current caller token and accepts a verified empty inventory',
    () async {
      final client = CloudDataWipeClient(
        endpoint: 'https://test.invalid/wipe-cloud-data',
        accessToken: () => 'fixture-token',
        httpClient: MockClient((request) async {
          expect(request.headers['Authorization'], 'Bearer fixture-token');
          expect(request.body, '{}');
          return http.Response('{"wiped":true,"files":0}', 200);
        }),
      );
      expect(await client.wipe(), 0);
      client.close();
    },
  );
}
