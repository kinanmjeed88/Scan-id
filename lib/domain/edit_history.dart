import 'validation.dart';

/// The owner must use immutable snapshots (Project is immutable).
/// Image bytes are not retained here; snapshots share immutable asset files.
class EditHistory<T> {
  EditHistory(T initial, {this.capacity = 50}) : _current = initial {
    require(capacity > 0 && capacity <= 500, 'حجم سجل التحرير غير صالح.');
  }
  final int capacity;
  T _current;
  final List<T> _past = [];
  final List<T> _future = [];
  T get current => _current;
  T? get previous => _past.isEmpty ? null : _past.last;
  T? get next => _future.isEmpty ? null : _future.last;
  bool get canUndo => _past.isNotEmpty;
  bool get canRedo => _future.isNotEmpty;

  void record(T next) {
    if (identical(next, _current)) {
      return;
    }
    _past.add(_current);
    if (_past.length > capacity) {
      _past.removeAt(0);
    }
    _current = next;
    _future.clear();
  }

  T undo() {
    if (canUndo) {
      _future.add(_current);
      _current = _past.removeLast();
    }
    return _current;
  }

  T redo() {
    if (canRedo) {
      _past.add(_current);
      _current = _future.removeLast();
    }
    return _current;
  }
}
