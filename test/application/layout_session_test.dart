import 'dart:io';
import 'package:scan_id/domain/validation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/application/contracts.dart';
import 'package:scan_id/application/layout_session.dart';
import 'package:scan_id/domain/page_layout.dart';
import 'package:scan_id/domain/project.dart';
import 'package:scan_id/persistence/local_project_repository.dart';
import '../fixtures.dart';

void main() {
  late Directory directory;
  late LocalProjectRepository repo;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('scan-layout-');
    repo = await LocalProjectRepository.open(directory);
  });
  tearDown(() async {
    await repo.close();
    await directory.delete(recursive: true);
  });
  test(
    'every command undo and redo commits a revision and reopens physical layout',
    () async {
      final a = assetFixture();
      for (final path in [a.originalPath, a.workingPath, a.thumbnailPath]) {
        final f = File('${directory.path}/$path');
        await f.parent.create(recursive: true);
        await f.writeAsBytes([1]);
      }
      final p = await repo.create(projectFixture(assets: [a]));
      final session = LayoutSession(p, repo);
      await session.apply(
        (p) => PageLayout.add(
          p,
          DocumentItem(
            id: 'one',
            assetId: a.id,
            x: 20,
            y: 30,
            width: 80,
            height: 50,
          ),
        ),
      );
      await session.apply((p) => PageLayout.move(p, 'one', 12, 8));
      await session.undo();
      expect(session.current.items.single.x, 20);
      await session.redo();
      expect(session.current.items.single.x, 32);
      await session.apply((p) => PageLayout.lock(p, 'one', true));
      await repo.close();
      repo = await LocalProjectRepository.open(directory);
      final reopened = await repo.get(p.id);
      expect(reopened.revision, 5);
      expect(reopened.items.single.x, 32);
      expect(reopened.items.single.y, 38);
      expect(reopened.items.single.locked, true);
    },
  );
  test(
    'concurrent commands cannot lose updates and a session cannot change project identity',
    () async {
      final p = await repo.create(projectFixture());
      final session = LayoutSession(p, repo);
      final first = session.apply((p) => p.copyWith(name: 'واحد'));
      await expectLater(
        session.apply((p) => p.copyWith(name: 'اثنان')),
        throwsA(isA<ValidationException>()),
      );
      await first;
      expect(session.current.name, 'واحد');
      expect(session.current.revision, 1);
      await expectLater(
        session.apply((_) => projectFixture(id: 'other')),
        throwsA(isA<ValidationException>()),
      );
      expect(session.current.id, p.id);
    },
  );
  test('stale save does not advance draft or history', () async {
    final p = await repo.create(projectFixture());
    final session = LayoutSession(p, repo);
    await repo.save(p.copyWith(name: 'أحدث'));
    await expectLater(
      session.apply((p) => p.copyWith(name: 'قديم')),
      throwsA(isA<RevisionConflict>()),
    );
    expect(session.current.name, p.name);
    expect(session.history.canUndo, false);
    expect(session.busy, false);
  });
  test('failed undo preserves redo and the last committed state', () async {
    final p = await repo.create(projectFixture());
    final session = LayoutSession(p, repo);
    await session.apply(
      (p) => p.copyWith(
        paper: PaperSettings(orientation: PaperOrientation.landscape),
      ),
    );
    await repo.save(session.current.copyWith(name: 'أحدث'));
    await expectLater(session.undo(), throwsA(isA<RevisionConflict>()));
    expect(session.current.paper.orientation, PaperOrientation.landscape);
    expect(session.history.canUndo, true);
    expect(session.history.canRedo, false);
  });
}
