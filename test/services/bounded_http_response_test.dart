import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:music_player_app/services/bounded_http_response.dart';

void main() {
  test('an already cancelled request never opens a connection', () async {
    var sends = 0;
    final client = MockClient((_) async {
      sends++;
      return http.Response('{}', 200);
    });
    addTearDown(client.close);
    await expectLater(
      sendBoundedHttpRequest(
        client,
        http.Request('GET', Uri.parse('https://resolver.test')),
        maxBytes: 100,
        timeout: const Duration(seconds: 1),
        cancelSignal: Future<void>.value(),
      ),
      throwsA(isA<HttpRequestCancelledException>()),
    );
    expect(sends, 0);
  });

  test(
    'cancellation aborts before headers and disposes a late response',
    () async {
      final cancellation = Completer<void>();
      final started = Completer<void>();
      final headers = Completer<http.StreamedResponse>();
      final aborted = Completer<void>();
      var bodyCancelled = false;
      final body = StreamController<List<int>>(
        onCancel: () => bodyCancelled = true,
      );
      final client = MockClient.streaming((request, _) {
        expect(request, isA<http.Abortable>());
        (request as http.Abortable).abortTrigger!.then(
          (_) => aborted.complete(),
        );
        started.complete();
        return headers.future;
      });
      addTearDown(client.close);
      final response = sendBoundedHttpRequest(
        client,
        http.Request('GET', Uri.parse('https://resolver.test')),
        maxBytes: 100,
        timeout: const Duration(seconds: 1),
        cancelSignal: cancellation.future,
      );
      final rejected = expectLater(
        response,
        throwsA(isA<HttpRequestCancelledException>()),
      );
      await started.future;
      cancellation.complete();
      await rejected;
      await aborted.future;
      headers.complete(http.StreamedResponse(body.stream, 200));
      await Future<void>.delayed(Duration.zero);
      expect(bodyCancelled, isTrue);
      await body.close();
    },
  );

  test('response size failure cancels the body and transport', () async {
    final aborted = Completer<void>();
    var bodyCancelled = false;
    late final StreamController<List<int>> body;
    body = StreamController<List<int>>(
      onListen: () => body.add(List<int>.filled(101, 1)),
      onCancel: () => bodyCancelled = true,
    );
    final client = MockClient.streaming((request, _) async {
      (request as http.Abortable).abortTrigger!.then((_) => aborted.complete());
      return http.StreamedResponse(body.stream, 200);
    });
    addTearDown(client.close);
    await expectLater(
      sendBoundedHttpRequest(
        client,
        http.Request('GET', Uri.parse('https://resolver.test')),
        maxBytes: 100,
        timeout: const Duration(seconds: 1),
      ),
      throwsA(isA<HttpResponseTooLargeException>()),
    );
    await aborted.future;
    expect(bodyCancelled, isTrue);
    await body.close();
  });

  test('a trickling body cannot extend the total request deadline', () async {
    final body = StreamController<List<int>>();
    final client = MockClient.streaming(
      (_, __) async => http.StreamedResponse(body.stream, 200),
    );
    addTearDown(client.close);
    final trickle = Timer.periodic(
      const Duration(milliseconds: 10),
      (_) => body.add([1]),
    );
    try {
      await expectLater(
        sendBoundedHttpRequest(
          client,
          http.Request('GET', Uri.parse('https://resolver.test')),
          maxBytes: 10000,
          timeout: const Duration(milliseconds: 80),
          totalTimeout: const Duration(milliseconds: 80),
        ),
        throwsA(isA<TimeoutException>()),
      );
    } finally {
      trickle.cancel();
      await body.close();
    }
  });

  test(
    'wrapping a request preserves its body, headers and redirect policy',
    () async {
      final client = MockClient.streaming((request, body) async {
        expect(request.method, 'POST');
        expect(request.headers['X-Test'], 'header');
        expect(request.followRedirects, isFalse);
        expect(request.maxRedirects, 2);
        expect(await body.bytesToString(), '{"value":1}');
        return http.StreamedResponse(Stream.value([123, 125]), 200);
      });
      addTearDown(client.close);
      final request = http.Request('POST', Uri.parse('https://resolver.test'))
        ..headers['X-Test'] = 'header'
        ..followRedirects = false
        ..maxRedirects = 2
        ..body = '{"value":1}';
      final response = await sendBoundedHttpRequest(
        client,
        request,
        maxBytes: 100,
        timeout: const Duration(seconds: 1),
        cancelSignal: Completer<void>().future,
      );
      expect(response.body, '{}');
      expect(response.request, same(request));
    },
  );

  test(
    'downloads without a total deadline retain the body inactivity policy',
    () async {
      final client = MockClient.streaming(
        (_, __) async => http.StreamedResponse(
          Stream<List<int>>.periodic(
            const Duration(milliseconds: 50),
            (_) => [1],
          ).take(4),
          200,
        ),
      );
      addTearDown(client.close);
      final response = await sendBoundedHttpRequest(
        client,
        http.Request('GET', Uri.parse('https://backup.test')),
        maxBytes: 100,
        timeout: const Duration(milliseconds: 150),
      );
      expect(response.bodyBytes, [1, 1, 1, 1]);
    },
  );
}
