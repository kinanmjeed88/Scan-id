/// Cooperative cancellation (ADR-009). A token is checked at stage
/// boundaries and between batch items; running native/CPU work is never
/// killed mid-operation — its result is discarded instead, so persistence
/// can never be corrupted by a cancel.
library;

/// Thrown by [CancellationToken.throwIfCancelled]. Not an error: callers
/// treat it as a clean early stop and report partial results.
class OperationCancelled implements Exception {
  const OperationCancelled();
  @override
  String toString() => 'أُلغيت العملية قبل اكتمالها.';
}

class CancellationToken {
  bool _cancelled = false;
  bool get isCancelled => _cancelled;

  /// Requests cancellation. Idempotent; takes effect at the next checkpoint.
  void cancel() => _cancelled = true;

  void throwIfCancelled() {
    if (_cancelled) throw const OperationCancelled();
  }
}
