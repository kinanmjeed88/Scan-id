import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/domain/document_kind.dart';
import 'package:scan_id/domain/recognition.dart';
import 'package:scan_id/domain/side_pairing.dart';

PairCandidate _candidate(
  String id, {
  DocumentKind kind = DocumentKind.unifiedNationalId,
  double aspect = 1.586,
  int importIndex = 0,
  String? sourceImageId,
  double? identifierMatchScore,
}) => PairCandidate(
  documentId: id,
  kind: kind,
  aspect: aspect,
  importIndex: importIndex,
  sourceImageId: sourceImageId ?? 'img-$id',
  identifierMatchScore: identifierMatchScore,
);

void main() {
  test('two adjacent same-kind cards are proposed but never auto-paired', () {
    final proposals = proposePairs([
      _candidate('doc-a', importIndex: 0),
      _candidate('doc-b', importIndex: 1),
    ]);
    expect(proposals, hasLength(1));
    final proposal = proposals.single;
    expect(proposal.resolution, PairingState.ambiguous,
        reason: 'no identifier evidence → capped below auto-accept');
    expect(proposal.confidence, lessThanOrEqualTo(identifierFreePairingCap));
    expect(proposal.confidence, greaterThanOrEqualTo(.7));
  });

  test('same kind alone is insufficient: distant, different shapes drop', () {
    final proposals = proposePairs([
      _candidate('doc-a', importIndex: 0, aspect: 1.58),
      _candidate('doc-b', importIndex: 9, aspect: 2.9),
    ]);
    expect(proposals, isEmpty);
  });

  test('different kinds never pair', () {
    final proposals = proposePairs([
      _candidate('doc-a', importIndex: 0),
      _candidate('doc-b', importIndex: 1, kind: DocumentKind.passport),
    ]);
    expect(proposals, isEmpty);
  });

  test('unknown kinds never pair', () {
    final proposals = proposePairs([
      _candidate('doc-a', importIndex: 0, kind: DocumentKind.unknown),
      _candidate('doc-b', importIndex: 1, kind: DocumentKind.unknown),
    ]);
    expect(proposals, isEmpty);
  });

  test('two cards segmented from ONE photo are different documents', () {
    final proposals = proposePairs([
      _candidate('doc-a', importIndex: 0, sourceImageId: 'img-1'),
      _candidate('doc-b', importIndex: 0, sourceImageId: 'img-1'),
    ]);
    expect(proposals, isEmpty);
  });

  test('identifier evidence can push a pair into auto-accept', () {
    final proposals = proposePairs([
      _candidate('doc-a', importIndex: 0, identifierMatchScore: .99),
      _candidate('doc-b', importIndex: 1, identifierMatchScore: .99),
    ]);
    expect(proposals, hasLength(1));
    expect(proposals.single.confidence, greaterThan(identifierFreePairingCap));
    expect(proposals.single.resolution, PairingState.paired);
  });

  test('each document joins at most one proposal, deterministically', () {
    final proposals = proposePairs([
      _candidate('doc-a', importIndex: 0),
      _candidate('doc-b', importIndex: 1),
      _candidate('doc-c', importIndex: 2),
    ]);
    final ids = <String>{};
    for (final proposal in proposals) {
      expect(ids.add(proposal.firstDocumentId), isTrue);
      expect(ids.add(proposal.secondDocumentId), isTrue);
    }
    // Deterministic across runs.
    final again = proposePairs([
      _candidate('doc-a', importIndex: 0),
      _candidate('doc-b', importIndex: 1),
      _candidate('doc-c', importIndex: 2),
    ]);
    expect(
      [for (final p in again) '${p.firstDocumentId}+${p.secondDocumentId}'],
      [
        for (final p in proposals)
          '${p.firstDocumentId}+${p.secondDocumentId}',
      ],
    );
  });

  test('proposal ids are ordered and reasons are machine-readable', () {
    final proposals = proposePairs([
      _candidate('doc-z', importIndex: 0),
      _candidate('doc-a', importIndex: 1),
    ]);
    final proposal = proposals.single;
    expect(proposal.firstDocumentId, 'doc-a');
    expect(proposal.secondDocumentId, 'doc-z');
    expect(proposal.reasons, isNotEmpty);
  });
}
