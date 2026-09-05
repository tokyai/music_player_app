import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

class HttpResponseTooLargeException implements Exception {
  final int maxBytes;

  const HttpResponseTooLargeException(this.maxBytes);

  @override
  String toString() => 'HTTP response exceeds $maxBytes bytes';
}

/// Signals that the owner of a request no longer needs its response.
///
/// This is deliberately separate from [TimeoutException]: callers can treat a
/// cancelled request as a normal lifecycle event instead of reporting a
/// network failure to the user.
class HttpRequestCancelledException implements Exception {
  const HttpRequestCancelledException();

  @override
  String toString() => 'HTTP request cancelled';
}

Future<http.Response> sendBoundedHttpRequest(
  http.Client client,
  http.BaseRequest request, {
  required int maxBytes,
  required Duration timeout,
  Future<void>? cancelSignal,
}) async {
  final streamed = await awaitWithCancellation(
    client.send(request).timeout(timeout),
    cancelSignal,
  );
  final bodyBytes = await _readBoundedResponse(
    streamed.stream,
    maxBytes: maxBytes,
    timeout: timeout,
    cancelSignal: cancelSignal,
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
  Future<void>? cancelSignal,
}) async {
  final bytes = BytesBuilder(copy: false);
  final result = Completer<Uint8List>();
  StreamSubscription<List<int>>? subscription;
  Timer? inactivityTimer;
  StreamSubscription<void>? cancellationSubscription;
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
  // Listening to the signal lets us cancel the stream subscription as soon as
  // a race loses or its owning page is disposed. The callback is harmless once
  // the response has already completed, and the signal itself is bounded by
  // the caller's operation lifetime.
  if (cancelSignal != null) {
    cancellationSubscription = cancelSignal.asStream().listen((_) {
      completeError(const HttpRequestCancelledException(), StackTrace.current);
    });
  }
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
    // A page-lifetime signal may intentionally remain pending. Detach the
    // listener without awaiting the signal's eventual completion.
    unawaited(cancellationSubscription?.cancel());
    if (!streamEnded) {
      unawaited(_cancelSubscriptionQuietly(subscription));
    }
  }
}

Future<T> awaitWithCancellation<T>(
  Future<T> operation,
  Future<void>? cancelSignal,
) async {
  if (cancelSignal == null) return operation;
  final result = Completer<T>();
  var completed = false;
  StreamSubscription<void>? cancellationSubscription;

  void completeValue(T value) {
    if (completed) return;
    completed = true;
    result.complete(value);
  }

  void completeError(Object error, StackTrace stackTrace) {
    if (completed) return;
    completed = true;
    result.completeError(error, stackTrace);
  }

  unawaited(
    operation.then<void>(
      completeValue,
      onError: (Object error, StackTrace stackTrace) {
        completeError(error, stackTrace);
      },
    ),
  );
  cancellationSubscription = cancelSignal.asStream().listen((_) {
    completeError(const HttpRequestCancelledException(), StackTrace.current);
  });
  try {
    return await result.future;
  } finally {
    // The signal can outlive a successful request; cancelling the subscription
    // is enough to release the listener and must not wait for that signal.
    unawaited(cancellationSubscription.cancel());
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
