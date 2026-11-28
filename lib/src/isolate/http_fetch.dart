import 'dart:typed_data';

/// A completed download plus how long the server took to start answering.
class HttpFetchResult {
  const HttpFetchResult(this.bytes, this.firstByte);

  /// The response body.
  final Uint8List bytes;

  /// Time from sending the request to receiving the response headers. This is
  /// the round trip plus server think time and, unlike the total time, does
  /// not grow with how many other requests share the link.
  final Duration firstByte;
}

/// Lets the caller abort one request after it started.
///
/// Cancelling closes the connection, so the request stops using bandwidth
/// straight away. The request's future then fails with a cancelled
/// `TileLoadException`. Cancelling twice, or after the request finished, does
/// nothing.
class HttpFetchHandle {
  bool _cancelled = false;
  void Function()? _onCancel;

  /// Whether [cancel] was called.
  bool get isCancelled => _cancelled;

  /// Aborts the request this handle was given to.
  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    final callback = _onCancel;
    _onCancel = null;
    callback?.call();
  }

  /// Called by the transport that runs the request. Runs [onCancel] at once if
  /// the handle was cancelled before the request started.
  void attach(void Function() onCancel) {
    if (_cancelled) {
      onCancel();
    } else {
      _onCancel = onCancel;
    }
  }

  /// Called by the transport when the request ended, so a late [cancel] does
  /// not reach a request that no longer exists.
  void detach() => _onCancel = null;
}
