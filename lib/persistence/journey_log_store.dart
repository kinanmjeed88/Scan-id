/// On-device storage for the per-image journey log.
///
/// Design constraints, in order of importance:
///
/// - **Bounded.** The log is a diagnostic aid, not a history of the project. It
///   keeps the newest entries within a fixed entry cap AND a fixed byte cap, so
///   a device that scans for years cannot fill its storage with reports.
/// - **Never load-bearing.** A failed write or a damaged file must not affect
///   the import that produced it. Reads are tolerant: a malformed entry is
///   dropped and the rest is still reported.
/// - **Atomic.** Entries are rewritten into a temporary file and swapped in, so
///   an interrupted write leaves the previous log intact instead of a truncated
///   JSON document.
/// - **Private.** Entries carry stage facts only (see [ImageJourney]); the store
///   adds nothing of its own and never writes recognized text or image bytes.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

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

  static const int schemaVersion = 1;
  static const String fileName = 'image_journeys.json';

  final Future<Directory> Function() _supportDirectory;
  Future<void> _tail = Future<void>.value();
  File? _file;

  @override
  Future<List<ImageJourney>> read() => _exclusive(_readUnlocked);

  @override
  Future<JourneyLogStats> stats() => _exclusive(() async {
    final journeys = await _readUnlocked();
    final file = await _resolveFile(create: false);
    var bytes = 0;
    if (file != null) {
      try {
        if (await file.exists()) bytes = await file.length();
      } on FileSystemException {
        bytes = 0;
      }
    }
    return JourneyLogStats(entries: journeys.length, bytes: bytes);
  });

  @override
  Future<void> append(Iterable<ImageJourney> journeys) => _exclusive(() async {
    final incoming = journeys.toList();
    if (incoming.isEmpty) return;
    final existing = await _readUnlocked();
    // Newest first, and a re-written run replaces its own earlier entry
    // instead of appearing twice.
    final merged = <String, ImageJourney>{
      for (final journey in incoming) journey.id: journey,
    };
    for (final journey in existing) {
      merged.putIfAbsent(journey.id, () => journey);
    }
    var kept = merged.values.take(maxEntries).toList();
    while (kept.length > 1 && _encodedBytes(kept) > maxBytes) {
      kept = kept.sublist(0, kept.length - 1);
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

  Future<List<ImageJourney>> _readUnlocked() async {
    final file = await _resolveFile(create: false);
    if (file == null) return const [];
    String raw;
    try {
      if (!await file.exists()) return const [];
      raw = await file.readAsString();
    } on FileSystemException {
      return const [];
    }
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return const [];
    }
    if (decoded is! Map<String, Object?>) return const [];
    final version = decoded['version'];
    if (version != schemaVersion) return const [];
    final entries = decoded['journeys'];
    if (entries is! List) return const [];
    final journeys = <ImageJourney>[];
    for (final entry in entries) {
      try {
        journeys.add(ImageJourney.fromJson(entry));
      } on Object {
        // One damaged entry must not hide the others.
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
      try {
        await temporary.rename(file.path);
      } on FileSystemException {
        // Some platforms refuse to replace an existing file on rename.
        if (await file.exists()) await file.delete();
        await temporary.rename(file.path);
      }
    } on FileSystemException {
      // The report is a courtesy: never fail the import because it could not
      // be filed. The next append retries with a fresh temporary file.
      try {
        if (await temporary.exists()) await temporary.delete();
      } on FileSystemException {
        // Ignore: nothing else can be done here.
      }
    }
  }

  int _encodedBytes(List<ImageJourney> journeys) => utf8.encode(
    jsonEncode([for (final journey in journeys) journey.toJson()]),
  ).length;

  Future<File?> _resolveFile({required bool create}) async {
    final cached = _file;
    if (cached != null) return cached;
    try {
      final support = await _supportDirectory();
      final folder = Directory(
        '${support.path}${Platform.pathSeparator}image_journeys',
      );
      if (create) await folder.create(recursive: true);
      final file = File('${folder.path}${Platform.pathSeparator}$fileName');
      _file = file;
      return file;
    } on Object {
      return null;
    }
  }

  /// Serialises every operation: appends never interleave, and a reader always
  /// observes a whole file.
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
