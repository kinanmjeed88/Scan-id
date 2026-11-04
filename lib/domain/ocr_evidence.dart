/// Structured OCR output used as recognition EVIDENCE (ADR-007).
///
/// These values live in memory for the duration of one pipeline run. The
/// recognized text itself is never persisted, never logged and never placed in
/// a backup; only derived keyword scores (without the text) reach
/// `RecognitionEvidence`.
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
/// conservative score of a two-line/two-group anchor match, and the number of
/// distinct anchor groups seen. The matched text never leaves the pipeline run.
class OcrKeywordEvidence {
  OcrKeywordEvidence({
    required this.kind,
    required this.score,
    required this.matchedAnchorGroups,
  }) {
    require(
      score.isFinite && score >= 0 && score <= 1,
      'درجة دليل OCR يجب أن تكون بين 0 و1.',
    );
    require(
      matchedAnchorGroups >= 2,
      'يتطلب دليل OCR مجموعتي مراسي متميزتين على سطرين مختلفين.',
    );
  }
  final DocumentKind kind;
  final double score;
  final int matchedAnchorGroups;
}

/// One lexicon group: several spelling/recognition variants of the same
/// semantic anchor. A type requires its primary group plus at least one
/// different corroborating group on a different OCR line.
class _OcrAnchorGroup {
  const _OcrAnchorGroup(this.id, this.phrases, {this.primary = false});

  final String id;
  final List<String> phrases;
  final bool primary;
}

/// Conservative Iraqi-document text anchors. Issuer names and generic country
/// names are never sufficient alone. These rules are lexicon unit tests, not
/// an OCR engine or a measured field-accuracy claim.
const _ocrAnchors = <DocumentKind, List<_OcrAnchorGroup>>{
  DocumentKind.unifiedNationalId: [
    _OcrAnchorGroup('title', [
      'البطاقهالوطنيهالموحده',
      'البطاقهالوطنيه',
      'بطاقهوطنيه',
      'nationalcard',
      'nationalid',
    ], primary: true),
    _OcrAnchorGroup('identifier', [
      'الرقمالوطني',
      'رقمالبطاقه',
      'nationalnumber',
      'idnumber',
    ]),
    _OcrAnchorGroup('issuer', ['وزارهالداخليه', 'مديريهشؤونالبطاقهالوطنيه']),
  ],
  DocumentKind.civilStatusId: [
    _OcrAnchorGroup('title', [
      'هويهالاحوالالمدنيه',
      'بطاقهالاحوالالمدنيه',
      'هويهالجنسيه',
      'civilstatusidentity',
    ], primary: true),
    _OcrAnchorGroup('registry', [
      'سجلالنفوس',
      'رقمالسجل',
      'رقمالصحيفه',
      'civilregistry',
    ]),
    _OcrAnchorGroup('citizenship', ['الجنسيه', 'nationality']),
  ],
  DocumentKind.residenceCard: [
    _OcrAnchorGroup('title', [
      'بطاقهالسكن',
      'هويهالسكن',
      'بطاقهسكن',
      'residencecard',
    ], primary: true),
    _OcrAnchorGroup('address', [
      'المحله',
      'الزقاق',
      'رقمالدار',
      'رقمالعقار',
      'residentialaddress',
    ]),
    _OcrAnchorGroup('issuer', ['مديريهالبلديه', 'بلديه']),
  ],
  DocumentKind.rationCard: [
    _OcrAnchorGroup('title', [
      'البطاقهالتموينيه',
      'بطاقهتموينيه',
      'rationcard',
    ], primary: true),
    _OcrAnchorGroup('issuer', ['وزارهالتجاره', 'ministryoftrade']),
    _OcrAnchorGroup('rationDetails', [
      'الوكيلالتمويني',
      'المركزالتمويني',
      'الحصهالتموينيه',
      'rationcenter',
    ]),
  ],
  DocumentKind.passport: [
    _OcrAnchorGroup('title', [
      'جوازالسفر',
      'جوازسفر',
      'passport',
    ], primary: true),
    _OcrAnchorGroup('documentNumber', ['رقمالجواز', 'passportno']),
    _OcrAnchorGroup('personalDataLabels', ['dateofbirth', 'nationality']),
  ],
};

String _normalize(String value) => value
    .toLowerCase()
    .replaceAll(RegExp(r'[\u064B-\u065F\u0670\u0640]'), '')
    .replaceAll(RegExp(r'[أإآٱ]'), 'ا')
    .replaceAll('ؤ', 'و')
    .replaceAll('ئ', 'ي')
    .replaceAll('ة', 'ه')
    .replaceAll('ى', 'ي')
    .replaceAll('ک', 'ك')
    .replaceAll('ی', 'ي')
    .replaceAll(
      RegExp(r'[^a-z0-9\u0600-\u06FF\u0750-\u077F\u08A0-\u08FF]'),
      '',
    );

class _AnchorHit {
  const _AnchorHit(this.lineIndex, this.confidence);

  final int lineIndex;
  final double confidence;
}

/// Shortest phrase that may act as an anchor, in normalised characters.
///
/// A two-letter fragment matches inside unrelated words, so an anchor must be a
/// recognisable word or phrase; the shipped lexicons are all far longer, and the
/// floor exists to stop a future short entry from turning into a false anchor.
const int minAnchorLength = 3;

List<_AnchorHit> _hits(
  OcrTextResult result,
  List<String> normalizedLines,
  List<String> reversedLines,
  _OcrAnchorGroup group,
) {
  final hits = <_AnchorHit>[];
  for (var index = 0; index < result.lines.length; index++) {
    final line = normalizedLines[index];
    if (line.isEmpty) continue;
    // Arabic is read right-to-left and the exports differ in whether they emit
    // logical or visual order. Matching both orders costs one reversed string
    // per line and cannot invent a match: it only stops a correct recognition
    // from being discarded because the text arrived the other way round.
    final reversed = reversedLines[index];
    var matched = false;
    for (final phrase in group.phrases) {
      if (phrase.length < minAnchorLength) continue;
      if (line.contains(phrase) || reversed.contains(phrase)) {
        matched = true;
        break;
      }
    }
    if (!matched) continue;
    hits.add(_AnchorHit(index, result.lines[index].confidence));
  }
  return hits;
}

/// Derives keyword evidence from [result] only when a distinctive document
/// title and an independent corroborating anchor occur on separate lines. The
/// score is the lower OCR-line confidence of that pair; it is not a calibrated
/// probability that the document kind is correct. The recognized text itself
/// is discarded and never stored.
List<OcrKeywordEvidence> ocrKeywordEvidence(OcrTextResult result) {
  if (!result.isAvailable) return const [];
  final normalizedLines = [
    for (final line in result.lines) _normalize(line.text),
  ];
  final reversedLines = [
    for (final line in normalizedLines) reversedRunes(line),
  ];
  final evidence = <OcrKeywordEvidence>[];
  final kinds = _ocrAnchors.keys.toList()
    ..sort((a, b) => a.index.compareTo(b.index));

  for (final kind in kinds) {
    final groups = _ocrAnchors[kind]!;
    final primary = groups.singleWhere((group) => group.primary);
    final primaryHits = _hits(result, normalizedLines, reversedLines, primary);
    if (primaryHits.isEmpty) continue;

    double? bestScore;
    var bestGroupCount = 0;
    for (final primaryHit in primaryHits) {
      final supportingGroups = <String>{};
      var bestSupportConfidence = 0.0;
      for (final group in groups.where((entry) => !entry.primary)) {
        final support = _hits(
          result,
          normalizedLines,
          reversedLines,
          group,
        ).where((hit) => hit.lineIndex != primaryHit.lineIndex).toList();
        if (support.isEmpty) continue;
        supportingGroups.add(group.id);
        for (final hit in support) {
          if (hit.confidence > bestSupportConfidence) {
            bestSupportConfidence = hit.confidence;
          }
        }
      }
      if (supportingGroups.isEmpty) continue;
      final score = math
          .min(primaryHit.confidence, bestSupportConfidence)
          .toDouble();
      if (bestScore == null || score > bestScore) {
        bestScore = score;
        bestGroupCount = 1 + supportingGroups.length;
      }
    }
    if (bestScore == null) continue;
    evidence.add(
      OcrKeywordEvidence(
        kind: kind,
        score: bestScore,
        matchedAnchorGroups: bestGroupCount,
      ),
    );
  }
  return List.unmodifiable(evidence);
}
