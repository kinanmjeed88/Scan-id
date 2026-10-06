import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/domain/edit_history.dart';
import 'package:scan_id/domain/validation.dart';

import '../fixtures.dart';

void main() {
  test('undo and redo preserve the full immutable project', () {
    final first = projectFixture();
    final history = EditHistory(first);
    final second = first.copyWith(name: 'جديد');
    history.record(second);
    expect(history.undo(), same(first));
    expect(history.canRedo, isTrue);
    expect(history.redo(), same(second));
    expect(history.canRedo, isFalse);
  });
  test('new operation after undo truncates the redo branch', () {
    final history = EditHistory(0)
      ..record(1)
      ..record(2);
    history.undo();
    history.record(3);
    expect(history.canRedo, isFalse);
    expect(history.undo(), 1);
    expect(history.undo(), 0);
    expect(history.undo(), 0);
  });
  test('bounded history removes oldest entries', () {
    final history = EditHistory(0, capacity: 2)
      ..record(1)
      ..record(2)
      ..record(3);
    expect(history.undo(), 2);
    expect(history.undo(), 1);
    expect(history.canUndo, isFalse);
    expect(history.redo(), 2);
    expect(history.redo(), 3);
  });
  test('invalid history capacity fails in release mode too', () {
    expect(
      () => EditHistory(0, capacity: 0),
      throwsA(isA<ValidationException>()),
    );
  });
}
