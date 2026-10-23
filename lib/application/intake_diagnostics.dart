import '../domain/document_kind.dart';

/// Privacy-safe, debug-only pipeline transition entry.
///
/// Records internal IDs, numeric dimensions, and boundary/routing verdicts ONLY
/// — never image bytes, filenames, paths, OCR text, or personal content.
class IntakeDiagnosticEntry {
  const IntakeDiagnosticEntry({
    required this.stage,
    required this.assetId,
    required this.verdict,
    this.itemId,
    this.modelId,
    this.candidateCount,
    this.sourceWidth,
    this.sourceHeight,
    this.documentKind,
    this.sizeConfirmed,
    this.pageIndex,
    this.widthMm,
    this.heightMm,
    this.reasons = const [],
  });

  final String stage;
  final String assetId;
  final String? itemId;
  final String? modelId;
  final int? candidateCount;
  final int? sourceWidth;
  final int? sourceHeight;
  final String verdict;
  final DocumentKind? documentKind;
  final bool? sizeConfirmed;
  final int? pageIndex;
  final double? widthMm;
  final double? heightMm;
  final List<String> reasons;
}

/// Bounded in-memory diagnostic trace collector, disabled by default and
/// compile-time sealed off in Dart AOT Release builds (`dart.vm.product`).
class IntakeDiagnostics {
  IntakeDiagnostics._();

  static const int maxEntries = 128;

  /// Compile-time Release guard (`true` in `--release` / product builds).
  static const bool isReleaseBuild = bool.fromEnvironment('dart.vm.product');

  /// Disabled by default; never emits console output or persists to disk.
  /// Cannot activate recording when [isReleaseBuild] is `true`.
  static bool enabled = false;

  /// Test-only hook allowing debug-VM unit tests to verify the Release-mode
  /// lock path (`isReleaseBuild || debugSimulateReleaseBuild`). Has no effect
  /// on turning diagnostics ON in an actual Release build because
  /// [isReleaseBuild] short-circuits at compile time.
  static bool debugSimulateReleaseBuild = false;

  static final List<IntakeDiagnosticEntry> _buffer = <IntakeDiagnosticEntry>[];

  static bool get isActive =>
      !isReleaseBuild && !debugSimulateReleaseBuild && enabled;

  static List<IntakeDiagnosticEntry> get entries =>
      isReleaseBuild || debugSimulateReleaseBuild
      ? const <IntakeDiagnosticEntry>[]
      : List.unmodifiable(_buffer);

  static void record(IntakeDiagnosticEntry entry) {
    if (isReleaseBuild || debugSimulateReleaseBuild || !enabled) return;
    if (_buffer.length >= maxEntries) {
      _buffer.removeAt(0);
    }
    _buffer.add(entry);
  }

  static void clear() {
    _buffer.clear();
  }
}
