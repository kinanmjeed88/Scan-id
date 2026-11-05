/// Memoizes an asynchronous resource creation while allowing failed attempts
/// to be retried. A detached older attempt cannot clear a newer one.
class RetryableFuture<T> {
  Future<T>? _current;

  Future<T> getOrCreate(Future<T> Function() create) {
    final current = _current;
    if (current != null) return current;
    final created = Future<T>.sync(create);
    _current = created;
    created.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {
        if (identical(_current, created)) _current = null;
      },
    );
    return created;
  }

  /// Detaches the current attempt before its owner awaits disposal.
  Future<T>? take() {
    final current = _current;
    _current = null;
    return current;
  }
}
