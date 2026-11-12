/// Structured OCR output used as recognition EVIDENCE (ADR-007).
///
/// These values live in memory for the duration of one pipeline run. The
/// recognized text itself is never persisted, never logged and never placed in
/// a backup; only derived keyword scores (without the text) reach
/// `RecognitionEvidence`.
///
/// Classification is dictionary-driven (see [_evidenceGroups]): each document
/// kind owns independent evidence groups — a title, an optional structural
/// pattern (MRZ), and supporting field/issuer groups. A kind is evidenced
/// only when an anchor (title or structural) pairs with a non-overlapping
/// supporting group, so a generic government word, a personal name, a number
/// or a filename can never classify a document on its own. When two kinds
/// both evidence, the classifier reports a conflict and the document goes to
/// manual classification; nothing is forced.
library;

import 'dart:math' as math;

import 'document_kind.dart';
import 'ocr_decoding.dart';
import 'geometry.dart';
import 'validation.dart';

/// Whether an OCR engine could run at all.
enum OcrAvailability { available, unavailable }

/// One recognized text line with its measured confidence and, when the engine
/// provides it, a normalized bounding quadrilateral.
class OcrLine {
  OcrLine({required this.text, required this.confidence, this.bounds}) {
    require(
      confidence.isFinite && confidence >= 0 && confidence <= 1,
      'ثقة سطر OCR يجب أن تكون بين 0 و1.',
    );
    if (bounds != null) {
      require(bounds!.length == 4, 'حدود سطر OCR يجب أن تكون أربع نقاط.');
    }
  }
  final String text;
  final double confidence;
  final List<Point2>? bounds;
}

/// The complete outcome of one OCR attempt. Unavailability is an explicit
/// state, never an invented empty success; a failed engine reports
/// [OcrAvailability.unavailable] with a machine-safe reason.
class OcrTextResult {
  OcrTextResult.available({
    required this.lines,
    required this.engineVersion,
    this.orientationQuarterTurns,
  }) : availability = OcrAvailability.available,
       unavailableReason = null;

  OcrTextResult.unavailable({
    required this.unavailableReason,
    required this.engineVersion,
  }) : availability = OcrAvailability.unavailable,
       lines = const [],
       orientationQuarterTurns = null;

  final OcrAvailability availability;
  final List<OcrLine> lines;

  /// Orientation proposal from the engine (0–3 quarter turns), when provided.
  final int? orientationQuarterTurns;
  final String? unavailableReason;
  final String engineVersion;

  bool get isAvailable => availability == OcrAvailability.available;

  /// Mean line confidence, or null when no line was recognized. Absence of
  /// OCR evidence is represented by null, never by a fabricated zero.
  double? get confidence {
    if (!isAvailable || lines.isEmpty) return null;
    var sum = 0.0;
    for (final line in lines) {
      sum += line.confidence;
    }
    return sum / lines.length;
  }
}

/// A document-kind keyword hit derived from OCR text. Carries the kind, the
/// conservative score of an anchor-plus-support match, the number of distinct
/// evidence groups seen, and the matched group ids (fixed dictionary ids —
/// never recognized text, names or numbers).
class OcrKeywordEvidence {
  OcrKeywordEvidence({
    required this.kind,
    required this.score,
    required this.matchedAnchorGroups,
    this.matchedGroups = const [],
  }) {
    require(
      score.isFinite && score >= 0 && score <= 1,
      'درجة دليل OCR يجب أن تكون بين 0 و1.',
    );
    require(
      matchedAnchorGroups >= 2,
      'يتطلب دليل OCR مجموعتي مراسي متميزتين غير متداخلتين.',
    );
  }
  final DocumentKind kind;
  final double score;
  final int matchedAnchorGroups;

  /// Ids of the evidence groups that matched, in dictionary order. Fixed
  /// strings from the lexicon — never recognized text, names or numbers.
  final List<String> matchedGroups;
}

/// Role of one evidence group. A kind is evidenced only when an anchor
/// ([_EvidenceRole.title] or [_EvidenceRole.structural]) pairs with a
/// non-overlapping hit from a different group.
enum _EvidenceRole { title, structural, support }

/// One lexicon group: several spelling/recognition variants of the same
/// semantic anchor. A type requires its anchor group plus at least one
/// different corroborating group at a non-overlapping text span.
class _EvidenceGroup {
  const _EvidenceGroup(
    this.id,
    this.phrases, {
    this.role = _EvidenceRole.support,
    this.minimumGroups = 2,
    this.restatedBy = const <String>{},
  });

  final String id;
  final List<String> phrases;
  final _EvidenceRole role;

  /// How many independent groups, this one included, must agree before this
  /// group may anchor a kind. A printed title or an MRZ line names the
  /// document, so one further group corroborates it. A weaker anchor, one that
  /// identifies a format rather than naming the document, asks for more.
  final int minimumGroups;

  /// Groups that restate this anchor instead of corroborating it, and so never
  /// count toward [minimumGroups]: the printed label of a number is not
  /// evidence independent of the number itself.
  final Set<String> restatedBy;
}

/// Conservative Iraqi-document text anchors. Issuer names and generic country
/// names are never sufficient alone. These rules are lexicon unit tests, not
/// an OCR engine or a measured field-accuracy claim.
///
/// Phrases are written in ordinary orthography and normalized at compile time
/// (diacritics stripped, alef variants unified, ة→ه, ى→ي), so the dictionary
/// stays readable and the normalization rules live in exactly one place.
///
/// - National ID: the printed title plus its distinctive fields (الرقم
///   الوطني، فصيلة الدم، …) or the IDIRQ machine-readable zone.
/// - Residence (information card): the مكتب المعلومات المركزي office
///   headings plus household fields (اسم رب الأسرة، عنوان السكن، رقم
///   الاستمارة). The supporting استمارة form carries only the office stamp
///   and form fields (تاريخ تنظيم الاستمارة، التوقيع) and therefore never
///   evidences on its own.
/// - Passport: the printed title plus passport fields, or the P<IRQ
///   machine-readable zone.
/// - Civil status and ration keep their established lexicons unchanged.
const _evidenceGroups = <DocumentKind, List<_EvidenceGroup>>{
  DocumentKind.unifiedNationalId: [
    _EvidenceGroup('title', [
      'البطاقة الوطنية',
      'البطاقة الوطنية الموحدة',
      'البطاقة الوطنية الشخصية',
      'بطاقة الوطنية',
      'national card',
      'national id',
      'nationalcard',
      'nationalid',
    ], role: _EvidenceRole.title),
    _EvidenceGroup('mrz', [], role: _EvidenceRole.structural),
    // The number printed under the title, matched by its FORMAT and never by
    // its digits (see [_nationalNumberOf]). It anchors the card only together
    // with two further independent groups: on a small or distant photo the
    // title is the smallest print on the card and cannot be read, while this
    // number, the field labels and the issuer still are. The `identifier`
    // group is the LABEL of this same number, so it restates the anchor and
    // does not count toward the two.
    _EvidenceGroup(
      nationalNumberGroupId,
      [],
      role: _EvidenceRole.structural,
      minimumGroups: 3,
      restatedBy: {'identifier'},
    ),
    _EvidenceGroup('identifier', [
      'الرقم الوطني',
      'رقم البطاقة الوطنية',
      'رقم البطاقة',
      'national number',
      'id number',
      'nationalnumber',
      'idnumber',
    ]),
    _EvidenceGroup('fields', [
      'الاسم',
      'اسم الأب',
      'الأب',
      'اسم الجد',
      'الجد',
      'اللقب',
      'الأم',
      'الجنس',
      'تاريخ الولادة',
      'فصيلة الدم',
      'الزمرة',
      'زمرة الدم',
      'الرقم العائلي',
      'جهة الإصدار',
      'تاريخ الإصدار',
      'تاريخ الانتهاء',
      'تاريخ النفاذ',
      'محل الولادة',
    ]),
    _EvidenceGroup('issuer', [
      'وزارة الداخلية',
      'مديرية الأحوال المدنية والجوازات والإقامة',
      'مديرية شؤون البطاقة الوطنية',
      'مديرية الجنسية والمعلومات المدنية',
    ]),
  ],
  DocumentKind.civilStatusId: [
    _EvidenceGroup('title', [
      'هوية الأحوال المدنية',
      'بطاقة الأحوال المدنية',
      'هوية الجنسية',
      'civil status identity',
    ], role: _EvidenceRole.title),
    _EvidenceGroup('registry', [
      'سجل النفوس',
      'رقم السجل',
      'رقم الصحيفة',
      'civil registry',
    ]),
    _EvidenceGroup('citizenship', ['الجنسية', 'nationality']),
  ],
  DocumentKind.residenceCard: [
    _EvidenceGroup('title', [
      'بطاقة السكن',
      'هوية السكن',
      'بطاقة سكن',
      'بطاقة معلومات السكن',
      'بطاقة معلومات سكن',
      'residence card',
      'residencecard',
      'مكتب المعلومات المركزي',
      'مديرية مكتب المعلومات المركزي',
      'مديرية مكتب المعلومات',
      'مكتب المعلومات',
      'مكتب معلومات',
    ], role: _EvidenceRole.title),
    _EvidenceGroup('household', [
      'اسم رب الأسرة',
      'عنوان السكن',
      'رقم الاستمارة',
      'رقم السكن',
    ]),
    _EvidenceGroup('address', [
      'المحلة',
      'الزقاق',
      'رقم الدار',
      'رقم العقار',
      'residential address',
    ]),
    _EvidenceGroup('issuer', [
      'مديرية البلدية',
      'مديرية الجنسية العامة',
      'بلدية',
    ]),
  ],
  DocumentKind.rationCard: [
    _EvidenceGroup('title', [
      'البطاقة التموينية',
      'بطاقة تموينية',
      'ration card',
    ], role: _EvidenceRole.title),
    _EvidenceGroup('issuer', ['وزارة التجارة', 'ministry of trade']),
    _EvidenceGroup('rationDetails', [
      'الوكيل التمويني',
      'المركز التمويني',
      'الحصة التموينية',
      'ration center',
    ]),
  ],
  DocumentKind.passport: [
    _EvidenceGroup('title', [
      'جواز السفر',
      'جواز سفر',
      'جواز سفر عراقي',
      'passport',
      'iraqi passport',
    ], role: _EvidenceRole.title),
    _EvidenceGroup('mrz', [], role: _EvidenceRole.structural),
    _EvidenceGroup('documentNumber', [
      'رقم الجواز',
      'passport no',
      'passportno',
    ]),
    _EvidenceGroup('personalDataLabels', [
      'date of birth',
      'nationality',
      'full name',
      'surname',
      'date of issue',
      'date of expiry',
      'issuing authority',
      'place of birth',
      'mother name',
      'country code',
      'document number',
      'الجنسية',
      'تاريخ الولادة',
      'الاسم الكامل',
      'اسم الأم',
      'محل الولادة',
      'جهة الإصدار',
      'تاريخ الإصدار',
      'تاريخ الانتهاء',
      'نوع الجواز',
    ]),
  ],
};

/// Shortest phrase that may act as an anchor, in normalised characters.
///
/// A two-letter fragment matches inside unrelated words, so an anchor must be a
/// recognisable word or phrase; the shipped lexicons are all far longer, and the
/// floor exists to stop a future short entry from turning into a false anchor.
const int minAnchorLength = 3;

/// Confidence discount for a fuzzy (OCR-error-tolerant) hit, by edit distance.
/// Fuzzy evidence is always weaker than an exact read of the same line.
const double _fuzzyDiscount1 = .85;
const double _fuzzyDiscount2 = .7;

String _stripMarks(String value) =>
    value.replaceAll(RegExp(r'[\u064B-\u065F\u0670\u0640]'), '');

String _normalizeToken(String token) => token
    .toLowerCase()
    .replaceAll(RegExp(r'[أإآٱ]'), 'ا')
    .replaceAll('ؤ', 'و')
    .replaceAll('ئ', 'ي')
    .replaceAll('ة', 'ه')
    .replaceAll('ى', 'ي')
    .replaceAll('ک', 'ك')
    .replaceAll('ی', 'ي');

/// Normalized word tokens of one OCR line. Diacritics are stripped before
/// splitting so a vocalized word stays one token.
List<String> _tokensOf(String line) {
  final parts = _stripMarks(
    line,
  ).split(RegExp(r'[^a-zA-Z0-9\u0600-\u06FF\u0750-\u077F\u08A0-\u08FF]+'));
  return [
    for (final part in parts)
      if (part.isNotEmpty) _normalizeToken(part),
  ];
}

/// A dictionary phrase compiled to normalized tokens plus its space-stripped
/// form (the form searched in space-stripped lines, so merged OCR words still
/// match while partial-word matches are rejected by boundary alignment).
class _CompiledPhrase {
  const _CompiledPhrase(this.tokens, this.stripped);

  final List<String> tokens;
  final String stripped;
}

_CompiledPhrase _compilePhrase(String raw) {
  final tokens = _tokensOf(raw);
  return _CompiledPhrase(tokens, tokens.join());
}

class _CompiledGroup {
  const _CompiledGroup(
    this.id,
    this.role,
    this.phrases,
    this.minimumGroups,
    this.restatedBy,
  );

  final String id;
  final _EvidenceRole role;
  final List<_CompiledPhrase> phrases;
  final int minimumGroups;
  final Set<String> restatedBy;
}

List<_CompiledGroup> _compileGroups(List<_EvidenceGroup> groups) {
  final compiled = <_CompiledGroup>[];
  for (final group in groups) {
    final phrases = <_CompiledPhrase>[];
    for (final phrase in group.phrases) {
      final compiledPhrase = _compilePhrase(phrase);
      if (compiledPhrase.stripped.length >= minAnchorLength) {
        phrases.add(compiledPhrase);
      }
    }
    compiled.add(
      _CompiledGroup(
        group.id,
        group.role,
        phrases,
        group.minimumGroups,
        group.restatedBy,
      ),
    );
  }
  return compiled;
}

Map<DocumentKind, List<_CompiledGroup>> _compileAll(
  Map<DocumentKind, List<_EvidenceGroup>> groups,
) {
  final compiled = <DocumentKind, List<_CompiledGroup>>{};
  for (final entry in groups.entries) {
    compiled[entry.key] = _compileGroups(entry.value);
  }
  return compiled;
}

final _compiledGroups = _compileAll(_evidenceGroups);

/// One OCR line in one reading-order view: normalized tokens, their
/// space-stripped form, the token-boundary offsets inside that form, and the
/// measured line confidence.
class _LineView {
  _LineView(this.tokens, this.confidence)
    : stripped = tokens.join(),
      boundaries = _boundariesOf(tokens);

  final List<String> tokens;
  final String stripped;
  final List<int> boundaries;
  final double confidence;
}

List<int> _boundariesOf(List<String> tokens) {
  final boundaries = <int>[0];
  var offset = 0;
  for (final token in tokens) {
    offset += token.length;
    boundaries.add(offset);
  }
  return boundaries;
}

class _AnchorHit {
  const _AnchorHit(this.start, this.end, this.confidence);

  final int start;
  final int end;
  final double confidence;

  bool overlaps(_AnchorHit other) => start < other.end && other.start < end;
}

/// Exact hits of [phrase] in one view. A phrase may cross ONE OCR line break
/// (split titles), not arbitrary lines. Every hit must start and end on token
/// boundaries, so a phrase never matches inside a longer word.
List<_AnchorHit> _exactHits(List<_LineView> view, _CompiledPhrase phrase) {
  final hits = <_AnchorHit>[];
  var offset = 0;
  for (var index = 0; index < view.length; index++) {
    final line = view[index];
    final next = index + 1 < view.length ? view[index + 1] : null;
    if (line.stripped.isNotEmpty) {
      var start = line.stripped.indexOf(phrase.stripped);
      while (start >= 0) {
        final end = start + phrase.stripped.length;
        if (line.boundaries.contains(start) && line.boundaries.contains(end)) {
          hits.add(_AnchorHit(offset + start, offset + end, line.confidence));
        }
        start = line.stripped.indexOf(phrase.stripped, start + 1);
      }
    }
    if (next != null && line.stripped.isNotEmpty && next.stripped.isNotEmpty) {
      final window = line.stripped + next.stripped;
      final windowBoundaries = [
        ...line.boundaries,
        for (final boundary in next.boundaries) boundary + line.stripped.length,
      ];
      var start = window.indexOf(phrase.stripped);
      while (start >= 0) {
        final end = start + phrase.stripped.length;
        // Only hits that actually cross the line break are new here; hits
        // fully inside one line were already recorded above.
        if (start < line.stripped.length &&
            end > line.stripped.length &&
            windowBoundaries.contains(start) &&
            windowBoundaries.contains(end)) {
          hits.add(
            _AnchorHit(
              offset + start,
              offset + end,
              math.min(line.confidence, next.confidence).toDouble(),
            ),
          );
        }
        start = window.indexOf(phrase.stripped, start + 1);
      }
    }
    offset += line.stripped.length;
  }
  return hits;
}

/// Levenshtein distance, abandoning early once it exceeds [maxDistance].
/// Operates on UTF-16 code units; Arabic and Latin text here is BMP.
int _levenshtein(String a, String b, int maxDistance) {
  final m = a.length;
  final n = b.length;
  if ((m - n).abs() > maxDistance) return maxDistance + 1;
  var previous = List<int>.generate(n + 1, (j) => j);
  for (var i = 1; i <= m; i++) {
    final current = List<int>.filled(n + 1, 0);
    current[0] = i;
    var rowMinimum = current[0];
    for (var j = 1; j <= n; j++) {
      final cost = a[i - 1] == b[j - 1] ? 0 : 1;
      current[j] = math.min(
        math.min(previous[j] + 1, current[j - 1] + 1),
        previous[j - 1] + cost,
      );
      rowMinimum = math.min(rowMinimum, current[j]);
    }
    if (rowMinimum > maxDistance) return maxDistance + 1;
    previous = current;
  }
  return previous[n];
}

/// OCR-error-tolerant hits of [phrase] in one view: whole-token windows whose
/// stripped form is within a small edit distance of the phrase. Only phrases
/// of at least six characters are fuzzied, and the hit confidence is
/// discounted, so approximate similarity alone can never carry a kind — the
/// two-independent-groups rule still applies.
List<_AnchorHit> _fuzzyHits(List<_LineView> view, _CompiledPhrase phrase) {
  final hits = <_AnchorHit>[];
  final length = phrase.stripped.length;
  if (length < 6) return hits;
  final maxEdits = length >= 10 ? 2 : 1;
  var offset = 0;
  for (final line in view) {
    final tokens = line.tokens;
    final count = phrase.tokens.length;
    if (tokens.length >= count) {
      final starts = <int>[];
      var position = 0;
      for (final token in tokens) {
        starts.add(position);
        position += token.length;
      }
      for (var window = 0; window + count <= tokens.length; window++) {
        final candidate = tokens.sublist(window, window + count).join();
        final distance = _levenshtein(candidate, phrase.stripped, maxEdits);
        if (distance == 0 || distance > maxEdits) continue;
        final start = starts[window];
        final end =
            starts[window + count - 1] + tokens[window + count - 1].length;
        final discount = distance == 1 ? _fuzzyDiscount1 : _fuzzyDiscount2;
        hits.add(
          _AnchorHit(offset + start, offset + end, line.confidence * discount),
        );
      }
    }
    offset += line.stripped.length;
  }
  return hits;
}

/// A validated machine-readable-zone (MRZ) line: the kind it structurally
/// belongs to and the line confidence (discounted when the prefix needed an
/// OCR-confusion tolerance).
class _MrzHit {
  const _MrzHit(this.kind, this.confidence);

  final DocumentKind kind;
  final double confidence;
}

final _passportMrzPrefix = RegExp(r'^P<IR[QO0]');
final _nationalMrzPrefix = RegExp(r'^IDIR[QO0]');
final _mrzCharset = RegExp(r'^[A-Z0-9<]+$');

/// Validates one raw OCR line as an MRZ line of a known kind.
///
/// The check is structural, never a bare substring: a passport line must start
/// with `P<IRQ` (Q may be misread as O/0), be at least twenty characters, use
/// only the MRZ alphabet and contain the `<<` name separator; a national-ID
/// line must start with `IDIRQ`, be at least twelve characters, use only the
/// MRZ alphabet and contain a digit. A stray `IRQ` in the middle of a line is
/// not an MRZ. The check runs on the raw line because normalization strips
/// the `<` separators the format depends on.
_MrzHit? _mrzOf(String rawLine, double confidence) {
  final compact = rawLine.toUpperCase().replaceAll(RegExp(r'\s+'), '');
  if (compact.length < 12 || !_mrzCharset.hasMatch(compact)) return null;
  if (_passportMrzPrefix.hasMatch(compact)) {
    if (compact.length >= 20 && compact.contains('<<')) {
      final tolerant = !compact.startsWith('P<IRQ');
      return _MrzHit(
        DocumentKind.passport,
        tolerant ? confidence * .9 : confidence,
      );
    }
    return null;
  }
  if (_nationalMrzPrefix.hasMatch(compact)) {
    if (compact.contains(RegExp(r'\d'))) {
      final tolerant = !compact.startsWith('IDIRQ');
      return _MrzHit(
        DocumentKind.unifiedNationalId,
        tolerant ? confidence * .9 : confidence,
      );
    }
    return null;
  }
  return null;
}

/// Structural MRZ hits of [kind] in view 0 (the as-emitted reading order;
/// MRZ lines are Latin and never rune-reversed). Each hit spans its whole
/// line, so it cannot overlap a text phrase on another line.
List<_AnchorHit> _mrzHits(
  OcrTextResult result,
  List<_LineView> view,
  DocumentKind kind,
) {
  final hits = <_AnchorHit>[];
  var offset = 0;
  for (var index = 0; index < result.lines.length; index++) {
    final line = result.lines[index];
    final mrz = _mrzOf(line.text, line.confidence);
    if (mrz != null && mrz.kind == kind) {
      hits.add(
        _AnchorHit(
          offset,
          offset + view[index].stripped.length,
          mrz.confidence,
        ),
      );
    }
    offset += view[index].stripped.length;
  }
  return hits;
}

/// Evidence-group id of the printed national number of the unified card.
const String nationalNumberGroupId = 'nationalNumber';

final _nationalNumberLine = RegExp(r'^(?:19|20)[0-9]{10}$');

/// Whether one raw OCR line is, as a whole, a printed national number.
///
/// The check is structural, like the MRZ one: the line must consist of exactly
/// twelve digits and nothing else, and they must open with a plausible year of
/// birth (19xx or 20xx), which is how the number is built. A longer number, a
/// number inside a sentence, a phone number or a date is not one. Only the
/// FORMAT is tested: the digits are neither kept nor returned, so no number
/// can travel out of this function.
bool _nationalNumberOf(String rawLine) {
  final buffer = StringBuffer();
  for (final rune in rawLine.runes) {
    if (rune == 0x20 || rune == 0x09 || rune == 0xA0) continue;
    if (rune >= 0x30 && rune <= 0x39) {
      buffer.writeCharCode(rune);
    } else if (rune >= 0x0660 && rune <= 0x0669) {
      buffer.writeCharCode(rune - 0x0660 + 0x30);
    } else if (rune >= 0x06F0 && rune <= 0x06F9) {
      buffer.writeCharCode(rune - 0x06F0 + 0x30);
    } else {
      return false;
    }
  }
  return _nationalNumberLine.hasMatch(buffer.toString());
}

/// Structural hits of the printed national number in [view]. A number reads
/// the same in both reading-order views, so, unlike an MRZ line, it is offered
/// in each of them: the labels that corroborate it are Arabic and are matched
/// in whichever view the engine's reading order makes them legible. Each hit
/// spans its whole line, so it cannot overlap a phrase on another line.
List<_AnchorHit> _nationalNumberHits(
  OcrTextResult result,
  List<_LineView> view,
) {
  final hits = <_AnchorHit>[];
  var offset = 0;
  for (var index = 0; index < result.lines.length; index++) {
    final line = result.lines[index];
    final length = view[index].stripped.length;
    if (_nationalNumberOf(line.text)) {
      hits.add(_AnchorHit(offset, offset + length, line.confidence));
    }
    offset += length;
  }
  return hits;
}

/// Derives keyword evidence from [result] only when an anchor and independent,
/// non-overlapping corroborating groups occur. A printed title or an MRZ line
/// needs one further group; the printed national number, which identifies a
/// format rather than naming the document, needs two. The score is the lowest
/// OCR-line confidence among the anchor and the groups it needed; it is not a
/// calibrated probability that the document kind is correct. The recognized
/// text itself is discarded and never stored.
List<OcrKeywordEvidence> ocrKeywordEvidence(OcrTextResult result) {
  if (!result.isAvailable) return const [];
  // Match in logical order and in per-line visual Arabic order separately.
  // The offsets are local to each view, so evidence is never paired across
  // views. A phrase may cross ONE OCR line break (split titles), not
  // arbitrary lines.
  final views = <List<_LineView>>[
    [
      for (final line in result.lines)
        _LineView(_tokensOf(line.text), line.confidence),
    ],
    [
      for (final line in result.lines)
        _LineView(_tokensOf(reversedRunes(line.text)), line.confidence),
    ],
  ];
  final evidence = <OcrKeywordEvidence>[];
  final kinds = _compiledGroups.keys.toList()
    ..sort((a, b) => a.index.compareTo(b.index));

  for (final kind in kinds) {
    final groups = _compiledGroups[kind]!;
    double? bestScore;
    var bestGroupCount = 0;
    var bestGroups = <String>[];
    for (var viewIndex = 0; viewIndex < views.length; viewIndex++) {
      final view = views[viewIndex];
      final hitsByGroup = <String, List<_AnchorHit>>{};
      for (final group in groups) {
        final hits = <_AnchorHit>[];
        for (final phrase in group.phrases) {
          final exact = _exactHits(view, phrase);
          if (exact.isNotEmpty) {
            hits.addAll(exact);
          } else {
            hits.addAll(_fuzzyHits(view, phrase));
          }
        }
        if (group.role == _EvidenceRole.structural) {
          if (group.id == nationalNumberGroupId) {
            hits.addAll(_nationalNumberHits(result, view));
          } else if (viewIndex == 0) {
            hits.addAll(_mrzHits(result, view, kind));
          }
        }
        if (hits.isNotEmpty) hitsByGroup[group.id] = hits;
      }
      for (final group in groups) {
        if (group.role == _EvidenceRole.support) continue;
        final anchors = hitsByGroup[group.id];
        if (anchors == null) continue;
        for (final anchor in anchors) {
          final accepted = <_AnchorHit>[anchor];
          final matched = <String>{group.id};
          final bestByGroup = <String, double>{};
          // Candidate supports: every hit from other groups, strongest
          // first. A hit overlapping an already accepted span (the anchor
          // or a stronger support) never counts as independent evidence.
          final candidates = <(String, _AnchorHit)>[
            for (final entry in hitsByGroup.entries)
              if (entry.key != group.id &&
                  !group.restatedBy.contains(entry.key))
                for (final hit in entry.value) (entry.key, hit),
          ]..sort((a, b) => b.$2.confidence.compareTo(a.$2.confidence));
          for (final (groupId, hit) in candidates) {
            if (accepted.any(hit.overlaps)) continue;
            accepted.add(hit);
            matched.add(groupId);
            final best = bestByGroup[groupId];
            if (best == null || hit.confidence > best) {
              bestByGroup[groupId] = hit.confidence;
            }
          }
          if (matched.length < group.minimumGroups) continue;
          // The weakest link the anchor NEEDED: its strongest corroborating
          // group when one is required (the pair rule, unchanged), and the
          // second strongest when two are.
          final supports = bestByGroup.values.toList()
            ..sort((a, b) => b.compareTo(a));
          final required = supports[group.minimumGroups - 2];
          final score = math.min(anchor.confidence, required).toDouble();
          if (bestScore == null ||
              score > bestScore ||
              (score == bestScore && matched.length > bestGroupCount)) {
            bestScore = score;
            bestGroupCount = matched.length;
            bestGroups = [
              for (final entry in groups)
                if (matched.contains(entry.id)) entry.id,
            ];
          }
        }
      }
    }
    if (bestScore == null) continue;
    evidence.add(
      OcrKeywordEvidence(
        kind: kind,
        score: bestScore,
        matchedAnchorGroups: bestGroupCount,
        matchedGroups: List.unmodifiable(bestGroups),
      ),
    );
  }
  return List.unmodifiable(evidence);
}

/// Arabic labels for the fixed evidence-group ids of the shipped lexicons.
///
/// This is the audit vocabulary shown to the person — "which kinds of evidence
/// were seen" — never the recognized text itself. The ids are dictionary keys
/// fixed at compile time, so no name, number or line of a document can travel
/// through this map.
const evidenceGroupLabels = <String, String>{
  'title': 'العنوان المطبوع',
  'mrz': 'منطقة القراءة الآلية',
  'identifier': 'حقل الرقم',
  nationalNumberGroupId: 'الرقم الوطني المطبوع',
  'fields': 'حقول الهوية',
  'issuer': 'الجهة المُصدِرة',
  'registry': 'السجل المدني',
  'citizenship': 'الجنسية',
  'household': 'حقول رب الأسرة',
  'address': 'حقول العنوان',
  'form': 'حقول الاستمارة',
  'rationDetails': 'بيانات التموين',
  'documentNumber': 'رقم الوثيقة',
  'personalDataLabels': 'حقول البيانات الشخصية',
};

/// Arabic label for one evidence-group id. A future lexicon group without a
/// label is reported generically instead of leaking its internal id.
String evidenceGroupLabel(String id) => evidenceGroupLabels[id] ?? 'دليل آخر';
