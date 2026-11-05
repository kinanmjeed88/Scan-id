import 'dart:async';
import 'dart:developer' as developer;

/// Owns one lazily created resource generation. Retiring a generation stops
/// new users from acquiring it, but disposal waits for all existing users.
/// A native operation that never finishes necessarily retains its generation:
/// a timeout cannot safely free a resource still used by native code.
class RetirableResource<T> {
  RetirableResource({required this.create, required this.dispose});

  final Future<T> Function() create;
  final Future<void> Function(T resource) dispose;
  _ResourceGeneration<T>? _current;

  Future<R> run<R>(Future<R> Function(T resource) use) async {
    final generation = _current ??= _ResourceGeneration<T>(
      Future<T>.sync(create),
    );
    generation.users++;
    try {
      final T resource;
      try {
        resource = await generation.resource;
      } catch (_) {
        if (identical(_current, generation)) _current = null;
        rethrow;
      }
      return await use(resource);
    } finally {
      generation.users--;
      if (generation.retired && generation.users == 0) {
        _disposeWhenIdle(generation);
      }
    }
  }

  /// Detaches the current generation. The returned future completes after its
  /// users finish and disposal has been attempted; it may never complete if a
  /// native operation never returns. Repeated retirement cannot double-close.
  Future<void> retire() {
    final generation = _current;
    _current = null;
    if (generation == null) return Future<void>.value();
    generation.retired = true;
    if (generation.users == 0) _disposeWhenIdle(generation);
    return generation.disposed.future;
  }

  void _disposeWhenIdle(_ResourceGeneration<T> generation) {
    if (generation.disposalStarted) return;
    generation.disposalStarted = true;
    unawaited(() async {
      try {
        final resource = await generation.resource;
        await dispose(resource);
      } catch (error) {
        // A failed creation has nothing to release. A disposal failure must
        // not become an unhandled asynchronous error or log document content.
        developer.log(
          'resource disposal failed type=${error.runtimeType}',
          name: 'scan_id.resource',
        );
      } finally {
        generation.disposed.complete();
      }
    }());
  }
}

class _ResourceGeneration<T> {
  _ResourceGeneration(this.resource);

  final Future<T> resource;
  final Completer<void> disposed = Completer<void>();
  int users = 0;
  bool retired = false;
  bool disposalStarted = false;
}
