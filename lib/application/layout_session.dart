import '../domain/edit_history.dart';
import '../domain/project.dart';
import '../domain/validation.dart';
import 'contracts.dart';

/// Persist before advancing history. Failed saves leave both stacks intact.
/// A busy session rejects concurrent commands instead of overwriting a snapshot.
class LayoutSession {
  LayoutSession(Project project, this.repository)
    : _current = project,
      history = EditHistory(project);
  final ProjectRepository repository;
  final EditHistory<Project> history;
  Project _current;
  Project get current => _current;
  bool busy = false;
  Future<void> apply(Project Function(Project) operation) =>
      _save(() => operation(_current), 0);
  Future<void> undo() async {
    if (history.canUndo) await _save(() => history.previous!, -1);
  }

  Future<void> redo() async {
    if (history.canRedo) await _save(() => history.next!, 1);
  }

  Future<void> _save(Project Function() operation, int direction) async {
    require(!busy, 'جارٍ حفظ العملية السابقة.');
    busy = true;
    try {
      final next = operation().copyWith(
        revision: _current.revision,
        updatedAt: _current.updatedAt,
      );
      require(
        next.id == _current.id && next.createdAt == _current.createdAt,
        'لا يجوز تغيير هوية المشروع داخل جلسة التحرير.',
      );
      final saved = await repository.save(next);
      if (direction < 0) {
        history.undo();
      } else if (direction > 0) {
        history.redo();
      } else {
        history.record(saved);
      }
      _current = saved;
    } finally {
      busy = false;
    }
  }
}
