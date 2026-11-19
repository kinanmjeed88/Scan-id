import 'document_kind.dart';
import 'recognition.dart';

/// The choices the person makes about a batch of images BEFORE intake runs.
///
/// Every field is an explicit decision with a declared default, because the
/// alternative — inferring intent from what the user did not touch — is exactly
/// the kind of guess this project refuses elsewhere. An untouched option keeps
/// its documented default, and [confirmed] marks the options the person ticked
/// with a check, so the report can say which ones were chosen rather than
/// assumed.
///
/// Pure Dart: no widgets, no files, no pipeline imports. It is validated on
/// construction so a caller cannot hand the pipeline an impossible batch.
class IntakeOptions {
  const IntakeOptions({
    this.side = SideKind.unknown,
    this.kind = DocumentKind.unknown,
    this.acceptSuggestedBoundary = false,
    this.centerDocuments = true,
    this.multiDocument = false,
    this.confirmed = const {},
  });

  /// The default a user who ticks nothing gets.
  ///
  /// Deliberately the conservative one on every axis: the recogniser decides the
  /// side and the kind, the suggested boundary is NOT auto-accepted, centring is
  /// on (it is the behaviour the app already had), and multi-document detection
  /// stays off because it is not enabled for release.
  static const IntakeOptions defaults = IntakeOptions();

  /// Front/back for the whole batch. [SideKind.unknown] means «وجه واحد» — the
  /// user did not say it is a two-sided document, which is not the same as
  /// claiming it is a front. The distinction matters: [SideKind.front] is an
  /// assertion the person made, [SideKind.unknown] one they did not.
  final SideKind side;

  /// The document category for the whole batch. [DocumentKind.unknown] leaves
  /// the automatic recogniser to decide, per document.
  final DocumentKind kind;

  /// The person ticked «اقبل الحدود المقترحة»: whatever boundary the detector
  /// proposes is accepted without a review stop, however its aspect compares to
  /// the catalog. This is an approval of the DETECTOR's geometry, not a change
  /// to any threshold — the detector still refuses what it refuses.
  final bool acceptSuggestedBoundary;

  /// Centre the documents, using the same placement the app already performs.
  final bool centerDocuments;

  /// Run multi-document detection for this batch.
  ///
  /// Honoured only where the build permits it: see [multiDocumentAvailable].
  final bool multiDocument;

  /// Which options the person explicitly ticked.
  ///
  /// Carried into the journey log so «the user asked for this» can never be
  /// confused with «this was the default». Empty means nothing was confirmed.
  final Set<IntakeOptionKey> confirmed;

  /// Whether multi-document detection may run at all in this build.
  ///
  /// The release policy is `multiDocumentSegmentationEnabled = false`: there is
  /// no qualified region detector. This model therefore reports the request
  /// honestly and lets the caller say «requested but unavailable» instead of
  /// silently doing nothing, which is what a bare disabled flag does.
  static const bool multiDocumentAvailable = false;

  /// Whether the person asked for multi-document detection AND the build can
  /// deliver it.
  bool get multiDocumentRuns => multiDocument && multiDocumentAvailable;

  /// True when the person explicitly asked for something this build refuses.
  bool get multiDocumentRequestedButUnavailable =>
      multiDocument && !multiDocumentAvailable;

  /// Whether this batch carries an explicit side assertion.
  bool get assertsSide => side != SideKind.unknown;

  /// Whether this batch carries an explicit category.
  bool get assertsKind => kind != DocumentKind.unknown;

  /// Whether anything at all was confirmed, for the report's summary line.
  bool get hasConfirmations => confirmed.isNotEmpty;

  /// Records that [key] was ticked, without mutating this instance.
  IntakeOptions withConfirmed(IntakeOptionKey key, {bool value = true}) {
    final next = Set<IntakeOptionKey>.of(confirmed);
    if (value) {
      next.add(key);
    } else {
      next.remove(key);
    }
    return IntakeOptions(
      side: side,
      kind: kind,
      acceptSuggestedBoundary: acceptSuggestedBoundary,
      centerDocuments: centerDocuments,
      multiDocument: multiDocument,
      confirmed: Set.unmodifiable(next),
    );
  }

  /// Replaces the side choice, keeping every other option.
  IntakeOptions withSide(SideKind value) => IntakeOptions(
    side: value,
    kind: kind,
    acceptSuggestedBoundary: acceptSuggestedBoundary,
    centerDocuments: centerDocuments,
    multiDocument: multiDocument,
    confirmed: confirmed,
  );

  /// Replaces the category choice, keeping every other option.
  IntakeOptions withKind(DocumentKind value) => IntakeOptions(
    side: side,
    kind: value,
    acceptSuggestedBoundary: acceptSuggestedBoundary,
    centerDocuments: centerDocuments,
    multiDocument: multiDocument,
    confirmed: confirmed,
  );

  /// The same options with one boolean flipped.
  IntakeOptions copyWith({
    bool? acceptSuggestedBoundary,
    bool? centerDocuments,
    bool? multiDocument,
  }) => IntakeOptions(
    side: side,
    kind: kind,
    acceptSuggestedBoundary:
        acceptSuggestedBoundary ?? this.acceptSuggestedBoundary,
    centerDocuments: centerDocuments ?? this.centerDocuments,
    multiDocument: multiDocument ?? this.multiDocument,
    confirmed: confirmed,
  );

  /// One bounded line for the journey log: which decisions this batch carries.
  ///
  /// Names and codes only — never a filename, never recognized text. The log is
  /// shown in Settings and kept beside the project, so it may not carry personal
  /// data even when the person typed it.
  Iterable<String> get traceCodes => [
    'side=${side.name}',
    'kind=${kind.name}',
    'acceptBoundary=$acceptSuggestedBoundary',
    'center=$centerDocuments',
    'multiRequested=$multiDocument',
    'multiApplied=$multiDocumentRuns',
    for (final key in IntakeOptionKey.values)
      'confirmed.${key.name}=${confirmed.contains(key)}',
  ];

  @override
  String toString() =>
      'IntakeOptions(side: ${side.name}, kind: ${kind.name}, '
      'accept: $acceptSuggestedBoundary, center: $centerDocuments, '
      'multi: $multiDocument/${multiDocumentRuns})';
}

/// The options a person can tick, as stable keys.
///
/// A separate enum (not the field names) because the set is persisted into the
/// journey log and must not follow a rename of a field.
enum IntakeOptionKey {
  /// «وجه أول أو ثاني»
  side,

  /// «نوع المستمسك»
  kind,

  /// «موافقة على القص مهما كانت نسبته»
  acceptSuggestedBoundary,

  /// «توسيط المستمسكات»
  centerDocuments,

  /// «المستندات المتعددة»
  multiDocument,
}

extension IntakeOptionKeyDetails on IntakeOptionKey {
  String get label => switch (this) {
    IntakeOptionKey.side => 'الوجه (أول أو ثاني)',
    IntakeOptionKey.kind => 'نوع المستمسك',
    IntakeOptionKey.acceptSuggestedBoundary => 'موافقة على القص المقترح',
    IntakeOptionKey.centerDocuments => 'توسيط المستمسكات',
    IntakeOptionKey.multiDocument => 'المستندات المتعددة',
  };
}
