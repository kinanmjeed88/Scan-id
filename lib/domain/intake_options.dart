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
    this.partnerChoice,
  });

  /// The default a user who ticks nothing gets.
  ///
  /// Deliberately the conservative one on every axis: there is one unspecified face
  /// and automatic kind recognition, the suggested boundary is NOT auto-accepted, centring is
  /// on (it is the behaviour the app already had), and manual multi-selection
  /// stays off unless requested.
  static const IntakeOptions defaults = IntakeOptions();

  /// Front/back for the whole batch. [SideKind.unknown] means «وجه واحد» — the
  /// user did not say it is a two-sided document, which is not the same as
  /// claiming it is a front. The distinction matters: [SideKind.front] is an
  /// assertion the person made, [SideKind.unknown] one they did not.
  final SideKind side;

  /// The document category for the whole batch. [DocumentKind.unknown] leaves
  /// the automatic recogniser to decide, per document.
  final DocumentKind kind;

  /// Approve score-only refusals of an otherwise safe boundary. Unused when
  /// corners are drawn by hand; never grants a physical size.
  final bool acceptSuggestedBoundary;

  /// Centre the documents, using the same placement the app already performs.
  final bool centerDocuments;

  /// Open the manual four-corner workspace. Never enables segmentation.
  final bool multiDocument;

  /// Which options the person explicitly ticked.
  ///
  /// Carried into the journey log so «the user asked for this» can never be
  /// confused with «this was the default». Empty means nothing was confirmed.
  final Set<IntakeOptionKey> confirmed;

  final IntakePartnerChoice? partnerChoice;

  IntakeRoute get route => multiDocument
      ? IntakeRoute.manualSelections
      : assertsKind
      ? IntakeRoute.singleManualKind
      : IntakeRoute.singleAutomaticKind;

  /// Whether this batch carries an explicit side assertion.
  bool get assertsSide => side != SideKind.unknown;

  /// Whether this batch carries an explicit category.
  bool get assertsKind => kind != DocumentKind.unknown;

  static const intakeSideField = 'intakeSide';

  UserOverride get recordOverride => UserOverride(
    side: side,
    documentKind: assertsKind ? kind : null,
    fields: [
      intakeSideField,
      if (assertsKind) 'documentKind',
      if (partnerChoice case final choice?) choice.code,
    ],
  );

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
      partnerChoice: partnerChoice,
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
    IntakePartnerChoice? partnerChoice,
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
    partnerChoice: (multiDocument ?? this.multiDocument)
        ? null
        : partnerChoice ?? this.partnerChoice,
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
    'route=${route.name}',
    if (partnerChoice case final choice?) choice.code,
    for (final key in IntakeOptionKey.values)
      'confirmed.${key.name}=${confirmed.contains(key)}',
  ];

  /// Read the option codes already used on disk (including older reports).
  static IntakeOptions? fromTraceCodes(Object? raw) {
    if (raw is! List) return null;
    final codes = raw.whereType<String>().toSet();
    final side = SideKind.values
        .where((s) => codes.contains('side=${s.name}'))
        .firstOrNull;
    final kind = DocumentKind.values
        .where((k) => codes.contains('kind=${k.name}'))
        .firstOrNull;
    if (side == null ||
        kind == null ||
        !IntakeRoute.values.any(
          (route) => codes.contains('route=${route.name}'),
        )) {
      return null;
    }
    return IntakeOptions(
      side: side,
      kind: kind,
      partnerChoice: IntakePartnerChoice.fromCodes(codes),
      acceptSuggestedBoundary: codes.contains('acceptBoundary=true'),
      centerDocuments: !codes.contains('center=false'),
      multiDocument: codes.contains('multiRequested=true'),
      confirmed: Set.unmodifiable(
        IntakeOptionKey.values.where(
          (k) => codes.contains('confirmed.${k.name}=true'),
        ),
      ),
    );
  }

  @override
  String toString() =>
      'IntakeOptions(side: ${side.name}, kind: ${kind.name}, '
      'accept: $acceptSuggestedBoundary, center: $centerDocuments, '
      'multi: $multiDocument)';
}

/// Null choice = not offered, null itemId = explicitly continue unpaired.
/// This records intent only. Eligibility must be rechecked on the saved item.
class IntakePartnerChoice {
  const IntakePartnerChoice(this.itemId);
  final String? itemId;
  static const _prefix = 'intakePartner=';
  String get code => '$_prefix${itemId ?? ''}';
  static IntakePartnerChoice? fromCodes(Iterable<String> codes) {
    final code = codes.where((c) => c.startsWith(_prefix)).firstOrNull;
    if (code == null) return null;
    final id = code.substring(_prefix.length);
    return IntakePartnerChoice(id.isEmpty ? null : id);
  }
}

enum IntakeRoute { singleAutomaticKind, singleManualKind, manualSelections }

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
