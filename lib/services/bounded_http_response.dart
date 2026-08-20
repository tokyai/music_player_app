import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

class HttpResponseTooLargeException implements Exception {
  final int maxBytes;

  const HttpResponseTooLargeException(this.maxBytes);

  @override
  String toString() => 'HTTP response exceeds $maxBytes bytes';
}

Future<http.Response> sendBoundedHttpRequest(
  http.Client client,
  http.BaseRequest request, {
  required int maxBytes,
  required Duration timeout,
}) async {
  final streamed = await client.send(request).timeout(timeout);
  final bodyBytes = await _readBoundedResponse(
    streamed.stream,
    maxBytes: maxBytes,
    timeout: timeout,
  );
  return http.Response.bytes(
    bodyBytes,
    streamed.statusCode,
    request: request,
    headers: streamed.headers,
    isRedirect: streamed.isRedirect,
    persistentConnection: streamed.persistentConnection,
    reasonPhrase: streamed.reasonPhrase,
  );
}

Future<Uint8List> _readBoundedResponse(
  Stream<List<int>> stream, {
  required int maxBytes,
  required Duration timeout,
}) async {
  final bytes = BytesBuilder(copy: false);
  final result = Completer<Uint8List>();
  StreamSubscription<List<int>>? subscription;
  Timer? inactivityTimer;
  var received = 0;
  var completed = false;
  var streamEnded = false;

  void completeError(Object error, StackTrace stackTrace) {
    if (completed) return;
    completed = true;
    inactivityTimer?.cancel();
    final activeSubscription = subscription;
    if (activeSubscription != null) {
      unawaited(_cancelSubscriptionQuietly(activeSubscription));
    }
    result.completeError(error, stackTrace);
  }

  void armTimeout() {
    inactivityTimer?.cancel();
    inactivityTimer = Timer(
      timeout,
      () => completeError(
        TimeoutException('HTTP response body timed out', timeout),
        StackTrace.current,
      ),
    );
  }

  armTimeout();
  try {
    subscription = stream.listen(
      (chunk) {
        if (completed) return;
        received += chunk.length;
        if (received > maxBytes) {
          completeError(
            HttpResponseTooLargeException(maxBytes),
            StackTrace.current,
          );
          return;
        }
        bytes.add(chunk);
        armTimeout();
      },
      onError: completeError,
      onDone: () {
        if (completed) return;
        streamEnded = true;
        completed = true;
        inactivityTimer?.cancel();
        result.complete(bytes.takeBytes());
      },
      cancelOnError: true,
    );
  } catch (error, stack) {
    completeError(error, stack);
  }

  try {
    return await result.future;
  } finally {
    inactivityTimer?.cancel();
    if (!streamEnded) {
      unawaited(_cancelSubscriptionQuietly(subscription));
    }
  }
}

Future<void> _cancelSubscriptionQuietly(
  StreamSubscription<List<int>>? subscription,
) async {
  try {
    await subscription?.cancel();
  } catch (_) {
    // The request's primary error is more useful than a cancellation error.
  }
}
