/// Exports the per-image journey log as one portable JSON file.
///
/// The log is deliberately NOT part of a project backup: a backup restores a
/// project's images and layout, while the log is a per-device diagnostic that
/// belongs to no single project. When a report must travel — to a support
/// conversation, to a second device, or into an archive — this is the explicit
/// path for it: the person chooses the file, and nothing else is written.
///
/// The document is a stable, versioned shape so a reader other than this app
/// can tell which build produced it. It carries stage facts only: no OCR text,
/// no personal values, no images.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../domain/image_journey.dart';
import 'native_documents.dart';

/// The saved file's own format name and version, independent of the log's
/// on-device schema so the two can evolve separately.
const String journeyExportFormat = 'scan-id-journey-log';
const int journeyExportVersion = 1;

/// Writes a file to wherever the platform's save dialog points.
typedef SaveExportFile = Future<bool> Function(File source, String mime);

enum JourneyExportStatus {
  saved,

  /// The person closed the dialog: nothing was written anywhere.
  cancelled,

  /// There was nothing to export, so no file was even offered.
  empty,
}

class JourneyExportOutcome {
  const JourneyExportOutcome({
    required this.status,
    this.fileName,
    this.entries = 0,
    this.bytes = 0,
  });

  final JourneyExportStatus status;

  /// The suggested file name, so the UI can tell the person what to look for.
  final String? fileName;
  final int entries;
  final int bytes;

  bool get saved => status == JourneyExportStatus.saved;
}

/// `scan-id-journeys-2026-11-09-1345.json` — local time, no personal data.
String journeyExportFileName(DateTime local) {
  String two(int value) => value.toString().padLeft(2, '0');
  return 'scan-id-journeys-${local.year}-${two(local.month)}-'
      '${two(local.day)}-${two(local.hour)}${two(local.minute)}.json';
}

/// The exported document, newest entry first, exactly as the log stored it.
String encodeJourneyExport(
  List<ImageJourney> journeys, {
  required DateTime exportedAt,
  String? appVersion,
}) {
  final document = <String, Object?>{
    'format': journeyExportFormat,
    'version': journeyExportVersion,
    'exported_utc': exportedAt.toUtc().toIso8601String(),
    if (appVersion != null) 'app_version': appVersion,
    'entries': journeys.length,
    'journeys': [for (final journey in journeys) journey.toJson()],
  };
  return const JsonEncoder.withIndent('  ').convert(document);
}

/// Saves the log through the same native save path a backup uses.
class JourneyExporter {
  JourneyExporter({
    SaveExportFile? saveFile,
    Future<Directory> Function()? temporaryDirectory,
    DateTime Function()? clock,
  }) : _saveFile = saveFile ?? saveDocument,
       _temporaryDirectory = temporaryDirectory ?? getTemporaryDirectory,
       _clock = clock ?? DateTime.now;

  final SaveExportFile _saveFile;
  final Future<Directory> Function() _temporaryDirectory;
  final DateTime Function() _clock;

  /// Returns what happened, never throws for an empty log or a closed dialog.
  /// A write failure is surfaced to the caller, which words it for the person.
  Future<JourneyExportOutcome> export(List<ImageJourney> journeys) async {
    if (journeys.isEmpty) {
      return const JourneyExportOutcome(status: JourneyExportStatus.empty);
    }
    final now = _clock();
    final fileName = journeyExportFileName(now);
    final document = encodeJourneyExport(journeys, exportedAt: now);
    final bytes = utf8.encode(document).length;
    final folder = await _temporaryDirectory();
    final staging = await folder.createTemp('scan-journeys-');
    final file = File('${staging.path}${Platform.pathSeparator}$fileName');
    try {
      await file.writeAsString(document, flush: true);
      final saved = await _saveFile(file, 'application/json');
      return JourneyExportOutcome(
        status: saved
            ? JourneyExportStatus.saved
            : JourneyExportStatus.cancelled,
        fileName: saved ? fileName : null,
        entries: journeys.length,
        bytes: saved ? bytes : 0,
      );
    } finally {
      try {
        await staging.delete(recursive: true);
      } on FileSystemException {
        // The platform may have copied the file already; a leftover temporary
        // directory is a cache artefact, never a reason to fail the export.
      }
    }
  }
}
