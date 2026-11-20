/// The app-side contract for the per-image journey log.
///
/// Settings reads it, intake writes it, and neither knows where it is kept. The
/// implementation lives in the persistence layer; tests substitute their own.
library;

import '../domain/image_journey.dart';
import 'intake_stage_log.dart';

/// How much the log currently holds, so Settings can state a fact instead of
/// guessing: number of reported images and the bytes they occupy.
class JourneyLogStats {
  const JourneyLogStats({
    required this.entries,
    required this.bytes,
    this.unreadable = false,
  });

  static const JourneyLogStats empty = JourneyLogStats(entries: 0, bytes: 0);

  final int entries;
  final int bytes;

  /// True when strict reading failed; tolerant reads may still return entries.
  final bool unreadable;

  bool get isEmpty => entries == 0;

  /// Human-readable size, rounded up so a non-empty log never reads «0 ك.ب».
  String get sizeLabel {
    if (bytes <= 0) return '0 ك.ب';
    final kib = (bytes / 1024).ceil();
    if (kib < 1024) return '$kib ك.ب';
    return '${(kib / 1024).toStringAsFixed(1)} م.ب';
  }
}

/// Bounded, append-only record of what happened to each imported image.
///
/// Implementations must never throw from [read] because of unreadable content:
/// a damaged entry is dropped, and a damaged file reads as empty. Losing a
/// report must not become a second failure on top of the one it documents.
abstract interface class JourneyLog {
  /// Newest first, capped by the log's own bound.
  Future<List<ImageJourney>> read();

  Future<JourneyLogStats> stats();

  /// Adds one run's reports, keeping the newest entries within the bound.
  /// Duplicate ids are replaced rather than repeated. Throws on write or
  /// existing-log read failure so the caller can warn without failing import.
  Future<void> append(Iterable<ImageJourney> journeys);

  /// Removes the whole log. The projects it describes are untouched.
  Future<void> clear();

  /// Files the stage-by-stage report of ONE batch, next to the journeys.
  ///
  /// Separate from [append] because it answers a different question: the
  /// journeys say what each image became, this says which stages ran, which
  /// failed, and with what measured cause. Kept under its own bound so a long
  /// run of imports cannot push the journeys out, and vice versa.
  ///
  /// Implementations must be safe to call with nothing recorded: an empty
  /// report writes nothing.
  Future<void> appendStageReport(IntakeStageReport report);

  /// Newest first, capped by the store's own bound.
  Future<List<IntakeStageReport>> readStageReports();
}
