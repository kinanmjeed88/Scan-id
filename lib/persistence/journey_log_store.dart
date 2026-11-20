/// On-device storage for the per-image journey log.
///
/// Design constraints, in order of importance:
///
/// - **Bounded.** The log is a diagnostic aid, not a history of the project. It
///   keeps the newest entries within a fixed entry cap AND a fixed byte cap, so
///   a device that scans for years cannot fill its storage with reports.
/// - **Failure-aware.** A configured journal is required before intake opens
///   a source; failures after a project commit cannot undo the import. Reads
///   remain tolerant, while stats flag an unreadable or damaged file.
/// - **Failure-aware.** Entries are flushed to a temporary file before rename;
///   the old file is never explicitly deleted on rename failure. Crash or power
///   loss durability depends on the platform and has not been established.
/// - **Private.** Entries carry stage facts only (see [ImageJourney]); the store
///   adds nothing of its own and never writes recognized text or image bytes.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../application/intake_stage_log.dart';
import '../application/journey_log.dart';
import '../domain/image_journey.dart';

class LocalJourneyLog implements JourneyLog {
  LocalJourneyLog({
    Future<Directory> Function()? supportDirectory,
    this.maxEntries = 200,
    this.maxBytes = 512 * 1024,
  }) : _supportDirectory = supportDirectory ?? getApplicationSupportDirectory;

  /// Newest entries kept. Older ones are dropped, newest first.
  final int maxEntries;

  /// Hard ceiling for the whole file. Entries are dropped oldest-first until it
  /// holds; a single oversized entry is still written rather than losing the
  /// report that was just produced.
  final int maxBytes;

  /// Newest stage reports kept. Smaller than [maxEntries] because a report is
  /// far more detailed than a journey entry: a handful of the most recent runs
  /// is what a person debugging an import needs, and older ones are dead weight.
  final int maxStageReports = 20;

  static const int schemaVersion = 1;
  static const String fileName = 'image_journeys.json';

  /// The stage reports live in their own file with their own schema version.
  ///
  /// Separate from the journeys on purpose: a report is larger and more
  /// detailed, and filing one must never be able to evict the journeys that
  /// describe what the user actually got.
  static const int stageReportSchemaVersion = 1;
  static const String stageReportFileName = 'image_stage_reports.json';

  final Future<Directory> Function() _supportDirectory;
  // Different instances in the same isolate can target the same file. A
  // shared queue prevents lost updates and temporary-file races between them.
  // It is not an inter-process or inter-isolate lock.
  static Future<void> _tail = Future<void>.value();
  Directory? _folder;
  bool _folderReady = false;

  @override
  Future<List<ImageJourney>> read() => _exclusive(_readUnlocked);

  @override
  Future<JourneyLogStats> stats() => _exclusive(() async {
    List<ImageJourney> journeys;
    var unreadable = false;
    try {
      journeys = await _readUnlocked(strict: true);
    } on Object {
      unreadable = true;
      journeys = await _readUnlocked();
    }
    final file = await _resolveFile(create: false);
    var bytes = 0;
    if (file != null) {
      try {
        if (await file.exists()) bytes = await file.length();
      } on FileSystemException {
        bytes = 0;
      }
    }
    return JourneyLogStats(
      entries: journeys.length,
      bytes: bytes,
      unreadable: unreadable,
    );
  });

  @override
  Future<void> append(Iterable<ImageJourney> journeys) => _exclusive(() async {
    final incoming = journeys.toList();
    if (incoming.isEmpty) return;
    // All incoming checkpoints must fit: silently trimming part of a new batch
    // would allow processing without a durable initial record for every source.
    final incomingIds = incoming.map((entry) => entry.id).toSet();
    if (incomingIds.length > maxEntries ||
        (incoming.length > 1 && _encodedBytes(incoming) > maxBytes)) {
      throw StateError('Journey batch exceeds journal capacity');
    }
    final existing = await _readUnlocked(strict: true);
    // Newest first, and a re-written run replaces its own earlier entry
    // instead of appearing twice.
    final merged = <String, ImageJourney>{
      for (final journey in incoming) journey.id: journey,
    };
    for (final journey in existing) {
      merged.putIfAbsent(journey.id, () => journey);
    }
    // Never evict unfinished checkpoints, including ones from other batches.
    // Refuse the update if they cannot fit; callers can then prevent a new
    // intake or warn about a later update without silently losing recovery data.
    final kept = merged.values.toList();
    final requiredIds = {
      ...incomingIds,
      for (final journey in existing)
        if (journey.lifecycle == JourneyLifecycle.created ||
            journey.lifecycle == JourneyLifecycle.processing)
          journey.id,
    };
    while (kept.length > maxEntries ||
        (kept.length > 1 && _encodedBytes(kept) > maxBytes)) {
      final index = kept.lastIndexWhere(
        (entry) => !requiredIds.contains(entry.id),
      );
      if (index < 0) {
        throw StateError('Unfinished journeys exceed journal capacity');
      }
      kept.removeAt(index);
    }
    await _writeUnlocked(kept);
  });

  @override
  Future<void> clear() => _exclusive(() async {
    final file = await _resolveFile(create: false);
    if (file == null) return;
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // Nothing to clear, or the file is already gone.
    }
  });

  @override
  Future<void> appendStageReport(IntakeStageReport report) =>
      _exclusive(() async {
        if (report.logs.isEmpty) return;
        final encoded = utf8.encode(jsonEncode([report.toJson()])).length;
        if (encoded > maxBytes) {
          throw StateError('Stage report exceeds journal capacity');
        }
        final existing = await _readStageReportsUnlocked(strict: true);
        // Newest first; a re-filed batch replaces its own report instead of
        // appearing twice, exactly like a journey entry.
        final merged = <String, IntakeStageReport>{report.batchId: report};
        for (final other in existing) {
          merged.putIfAbsent(other.batchId, () => other);
        }
        final kept = merged.values.toList();
        while (kept.length > maxStageReports ||
            (kept.length > 1 && _stageReportBytes(kept) > maxBytes)) {
          kept.removeLast();
        }
        await _writeStageReportsUnlocked(kept);
      });

  @override
  Future<List<IntakeStageReport>> readStageReports() =>
      _exclusive(() => _readStageReportsUnlocked());

  Future<List<IntakeStageReport>> _readStageReportsUnlocked({
    bool strict = false,
  }) async {
    final file = await _resolveReportFile(create: false, strict: strict);
    if (file == null) return const [];
    String raw;
    try {
      if (!await file.exists()) return const [];
      raw = await file.readAsString();
    } on FileSystemException {
      if (strict) rethrow;
      return const [];
    }
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      if (strict) rethrow;
      return const [];
    }
    if (decoded is! Map<String, Object?> ||
        decoded['version'] != stageReportSchemaVersion ||
        decoded['reports'] is! List) {
      if (strict) throw const FormatException('Invalid stage report log');
      return const [];
    }
    final reports = <IntakeStageReport>[];
    for (final entry in decoded['reports'] as List) {
      final report = IntakeStageReport.fromJson(entry);
      if (report == null) {
        if (strict) throw const FormatException('Invalid stage report entry');
        continue;
      }
      reports.add(report);
    }
    return List.unmodifiable(reports);
  }

  Future<void> _writeStageReportsUnlocked(
    List<IntakeStageReport> reports,
  ) async {
    final file = await _resolveReportFile(create: true);
    if (file == null) return;
    final document = jsonEncode({
      'version': stageReportSchemaVersion,
      'updated_utc': DateTime.now().toUtc().toIso8601String(),
      'reports': [for (final report in reports) report.toJson()],
    });
    final temporary = File('${file.path}.tmp');
    try {
      await temporary.writeAsString(document, flush: true);
      await temporary.rename(file.path);
    } on Object {
      try {
        if (await temporary.exists()) await temporary.delete();
      } on FileSystemException {
        // The failed temporary file is not authoritative.
      }
      rethrow;
    }
  }

  int _stageReportBytes(List<IntakeStageReport> reports) => utf8
      .encode(jsonEncode([for (final report in reports) report.toJson()]))
      .length;

  Future<File?> _resolveReportFile({
    required bool create,
    bool strict = false,
  }) async {
    final folder = await _resolveFile(create: create, strict: strict);
    if (folder == null) return null;
    return File(
      '${folder.parent.path}${Platform.pathSeparator}$stageReportFileName',
    );
  }

  Future<List<ImageJourney>> _readUnlocked({bool strict = false}) async {
    final file = await _resolveFile(create: false, strict: strict);
    if (file == null) return const [];
    String raw;
    try {
      if (!await file.exists()) return const [];
      raw = await file.readAsString();
    } on FileSystemException {
      if (strict) rethrow;
      return const [];
    }
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      if (strict) rethrow;
      return const [];
    }
    if (decoded is! Map<String, Object?> ||
        decoded['version'] != schemaVersion ||
        decoded['journeys'] is! List) {
      if (strict) throw const FormatException('Invalid journey log');
      return const [];
    }
    final entries = decoded['journeys'] as List;
    final journeys = <ImageJourney>[];
    for (final entry in entries) {
      try {
        journeys.add(ImageJourney.fromJson(entry));
      } on Object {
        // Reading is tolerant; appending must not erase damaged entries.
        if (strict) rethrow;
      }
    }
    return List.unmodifiable(journeys);
  }

  Future<void> _writeUnlocked(List<ImageJourney> journeys) async {
    final file = await _resolveFile(create: true);
    if (file == null) return;
    final document = jsonEncode({
      'version': schemaVersion,
      'updated_utc': DateTime.now().toUtc().toIso8601String(),
      'journeys': [for (final journey in journeys) journey.toJson()],
    });
    final temporary = File('${file.path}.tmp');
    try {
      await temporary.writeAsString(document, flush: true);
      // Never delete the existing log on rename failure. A failed replacement
      // is reported to the caller, who may retry without losing the old file.
      await temporary.rename(file.path);
    } on Object {
      try {
        if (await temporary.exists()) await temporary.delete();
      } on FileSystemException {
        // The failed temporary file is not authoritative.
      }
      rethrow;
    }
  }

  int _encodedBytes(List<ImageJourney> journeys) => utf8
      .encode(jsonEncode([for (final journey in journeys) journey.toJson()]))
      .length;

  Future<File?> _resolveFile({
    required bool create,
    bool strict = false,
  }) async {
    try {
      final folder = _folder ??= Directory(
        '${(await _supportDirectory()).path}'
        '${Platform.pathSeparator}image_journeys',
      );
      // Resolving a path for a read must not create anything; creating it later
      // must actually call create, even when the path was resolved before.
      if (create && !_folderReady) {
        await folder.create(recursive: true);
        _folderReady = true;
      }
      return File('${folder.path}${Platform.pathSeparator}$fileName');
    } on Object {
      if (create || strict) rethrow;
      return null;
    }
  }

  /// Serialises operations across instances in this isolate only.
  Future<T> _exclusive<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        completer.complete(await action());
      } on Object catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }
}
