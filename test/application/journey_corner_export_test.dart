import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/application/image_journey_report.dart';
import 'package:scan_id/domain/geometry.dart';
import 'package:scan_id/domain/image_journey.dart';
import 'package:scan_id/domain/project.dart';
import 'package:scan_id/domain/recognition.dart';

import '../fixtures.dart';

/// Regression tests for the corner export in the image journey report.
///
/// The export exists so a boundary evaluation can compare measured corners
/// against human markings. That makes two kinds of mistake expensive, and both
/// are tested here by VALUE rather than by the presence of a key:
///
///   * a wrong coordinate that still looks like four plausible corners passes
///     every downstream geometry gate, so only the numbers catch it;
///   * a synthetic or guessed corner reported as if a detector produced it
///     would turn "no detection" into "accurate detection".

ImageAsset _asset(
  String id, {
  int width = 1200,
  int height = 1600,
  String? derivedFrom,
}) => ImageAsset(
  id: id,
  name: '$id.jpg',
  derivedFrom: derivedFrom,
  originalPath: 'projects/project1/assets/$id/original.png',
  workingPath: 'projects/project1/assets/$id/working.png',
  thumbnailPath: 'projects/project1/assets/$id/thumb.jpg',
  width: width,
  height: height,
);

/// A document side with an explicitly chosen detection polygon.
DocumentSide _side({
  String id = 's1',
  SideKind side = SideKind.unknown,
  List<Point2>? polygon,
  List<Point2>? suggested,
  String producer = 'cascade',
  List<String> trace = const [],
  List<String> diagnostics = const [],
  List<Point2>? processedCorners,
}) => DocumentSide(
  id: id,
  side: side,
  processedAsset: ProcessedAssetRef(
    workingPath: 'projects/project1/processed/$id/working.png',
    thumbnailPath: 'projects/project1/processed/$id/thumb.jpg',
    width: 400,
    height: 250,
    corners: processedCorners,
  ),
  detection: DetectionRef(
    detectionId: 'det-$id',
    producer: producer,
    version: 'v1',
    polygon: polygon,
    suggestedPolygon: suggested,
    detectionTrace: trace,
    boundaryDiagnostics: diagnostics,
  ),
);

DocumentRecord _record({
  required String id,
  required List<DocumentSide> sides,
  String source = 'a1',
}) => DocumentRecord(
  id: id,
  sourceImageId: source,
  sides: sides,
  pairing: PairingState.single,
  provenance: Provenance(
    sourceImageId: source,
    detectionIds: [for (final s in sides) 'det-${s.id}'],
    processedAssetVersion: 'smart-1',
    pipelineVersion: 'smart-1',
  ),
);

/// One single-sided document. Kept as a helper so a test reads as the case it
/// exercises instead of a nest of collection literals.
DocumentRecord _oneDocument(
  List<Point2>? polygon, {
  String id = 'd1',
  String? sideId,
  List<Point2>? suggested,
  String producer = 'cascade',
  List<String> trace = const [],
  List<String> diagnostics = const [],
}) => _record(
  id: id,
  sides: [
    _side(
      id: sideId ?? 's-$id',
      polygon: polygon,
      suggested: suggested,
      producer: producer,
      trace: trace,
      diagnostics: diagnostics,
    ),
  ],
);

/// A project holding [records], each placed on the page.
///
/// `Project` refuses an active document that has no layout item, so every
/// record gets the item a real intake would have created for it. The item
/// carries the record id, which is also what the report's `d<n>_` numbering
/// follows.
Project _project(
  List<DocumentRecord> records, {
  int width = 1200,
  int height = 1600,
}) => projectFixture(
  assets: [_asset('a1', width: width, height: height)],
  documents: records,
  items: [
    for (var i = 0; i < records.length; i++)
      DocumentItem(
        id: 'i${i + 1}',
        assetId: 'a1',
        documentId: records[i].id,
        sideId: records[i].sides.first.id,
        x: 10,
        y: 10.0 + i,
        width: 60,
        height: 40,
      ),
  ],
);

/// Builds the journey and returns the detection step.
JourneyStep _detection(
  Project project, {
  int? copiedWidth = 1200,
  int? copiedHeight = 1600,
  String name = 'ورقة.jpg',
}) {
  final journeys = buildImageJourneys(
    batchId: 'batch-0001',
    startedAt: DateTime.utc(2026, 11, 22, 10),
    images: [
      ImportedImageFact(
        name: name,
        assetId: 'a1',
        copiedWidth: copiedWidth,
        copiedHeight: copiedHeight,
      ),
    ],
    project: project,
  );
  return journeys.single.steps.firstWhere(
    (step) => step.stage == JourneyStage.detection,
  );
}

/// The exported ring, parsed back into numbers.
List<(double, double)> _corners(
  Map<String, Object?> fields, [
  String prefix = '',
]) {
  final raw = fields['${prefix}quadCorners'];
  expect(raw, isA<String>(), reason: 'expected ${prefix}quadCorners');
  return [
    for (final pair in (raw! as String).split(' '))
      (double.parse(pair.split(',')[0]), double.parse(pair.split(',')[1])),
  ];
}

void main() {
  group('an accepted quad is exported with real numbers', () {
    // A deliberately asymmetric, perspective-looking quad: four distinct
    // values per axis, so a swapped axis, a reversed ring or a rotated ring
    // all change the parsed list.
    final quad = [
      Point2(.1049, .2013),
      Point2(.8802, .1507),
      Point2(.9311, .8404),
      Point2(.0823, .7911),
    ];

    test('the four corners come back in the app ring order', () {
      final step = _detection(_project([_oneDocument(quad)]));

      expect(step.fields['quadStatus'], 'accepted');
      expect(step.fields['quadSpace'], 'originalNorm');
      final exported = _corners(step.fields);
      expect(exported, hasLength(4));
      // Exact values, position by position: TL, TR, BR, BL.
      expect(exported[0], (.1049, .2013));
      expect(exported[1], (.8802, .1507));
      expect(exported[2], (.9311, .8404));
      expect(exported[3], (.0823, .7911));
    });

    test('the ring is clockwise from top-left, as the app orders corners', () {
      final step = _detection(_project([_oneDocument(quad)]));
      final ring = _corners(step.fields);
      // Canonical ring: sums of x+y are minimal at the first corner.
      final sums = [for (final c in ring) c.$1 + c.$2];
      expect(sums[0], lessThan(sums[1]));
      expect(sums[0], lessThan(sums[3]));
      // Positive shoelace in screen space (y down) = clockwise on screen.
      var twiceArea = 0.0;
      for (var i = 0; i < 4; i++) {
        final a = ring[i];
        final b = ring[(i + 1) % 4];
        twiceArea += a.$1 * b.$2 - b.$1 * a.$2;
      }
      expect(twiceArea, greaterThan(0));
    });

    test('the reference frame is the copied source frame, in pixels', () {
      final step = _detection(
        _project([_oneDocument(quad)]),
        copiedWidth: 3024,
        copiedHeight: 4032,
      );
      expect(step.fields['quadWidth'], 3024);
      expect(step.fields['quadHeight'], 4032);
      expect(step.fields.containsKey('quadSize'), isFalse);
    });

    test('an unknown copy size is stated, never guessed', () {
      final step = _detection(
        _project([_oneDocument(quad)]),
        copiedWidth: null,
        copiedHeight: null,
      );
      expect(step.fields['quadSize'], 'unknown');
      expect(step.fields.containsKey('quadWidth'), isFalse);
      expect(step.fields.containsKey('quadHeight'), isFalse);
      // The coordinates are still the detector's, in range, and unchanged.
      expect(_corners(step.fields)[0], (.1049, .2013));
    });
  });

  group('the coordinate space is the source frame, not the model tensor', () {
    // The model works on a 256-wide letterboxed tensor. A leak of those
    // coordinates would produce values far above 1 — or plausible-looking
    // small numbers. Assert the exported values are the source-normalized
    // ones and that every component is inside [0, 1].
    test('a letterboxed edge quad stays within the normalized frame', () {
      // Corners that touch all four edges: the padding-absorbing case.
      final quad = [Point2(0, 0), Point2(1, 0), Point2(1, 1), Point2(0, 1)];
      final step = _detection(
        _project([_oneDocument(quad)]),
        copiedWidth: 4000,
        copiedHeight: 3000,
      );
      final ring = _corners(step.fields);
      for (final corner in ring) {
        expect(corner.$1, inInclusiveRange(0, 1));
        expect(corner.$2, inInclusiveRange(0, 1));
      }
      expect(ring[0], (0.0, 0.0));
      expect(ring[2], (1.0, 1.0));
    });

    test('half-pixel mapping keeps a sub-pixel corner sub-pixel', () {
      // 1200x1600 source; a corner at pixel (1, 2) is a tiny fraction.
      // 1 / (1200 - 1) and 2 / (1600 - 1) are the app's own convention.
      final quad = [
        Point2(1 / 1199, 2 / 1599),
        Point2(1199 / 1199, 2 / 1599),
        Point2(1199 / 1199, 1599 / 1599),
        Point2(1 / 1199, 1599 / 1599),
      ];
      final step = _detection(_project([_oneDocument(quad)]));
      final ring = _corners(step.fields);
      // 4-decimal rounding is the documented export precision.
      expect(ring[0], (0.0008, 0.0013));
      expect(ring[1].$1, 1.0);
      expect(ring[2], (1.0, 1.0));
    });

    test('different aspect ratios do not rescale the coordinates', () {
      for (final size in [(1000, 1000), (1200, 380), (380, 1200)]) {
        final quad = [
          Point2(.2, .2),
          Point2(.8, .2),
          Point2(.8, .8),
          Point2(.2, .8),
        ];
        final step = _detection(
          _project([_oneDocument(quad)], width: size.$1, height: size.$2),
          copiedWidth: size.$1,
          copiedHeight: size.$2,
        );
        final ring = _corners(step.fields);
        expect(ring[0], (.2, .2), reason: '$size');
        expect(ring[2], (.8, .8), reason: '$size');
        expect(step.fields['quadWidth'], size.$1);
      }
    });
  });

  group('invalid geometry is refused, never repaired', () {
    test('a bow-tie proposal exports no coordinates and names the reason', () {
      // Diagonal pairing: the classic crossed ring.
      final bowTie = [
        Point2(.1, .1),
        Point2(.9, .9),
        Point2(.9, .1),
        Point2(.1, .9),
      ];
      final step = _detection(
        _project([_oneDocument(null, suggested: bowTie)]),
      );
      expect(step.fields['quadStatus'], 'invalid');
      expect(step.fields['quadReason'], 'notConvex');
      // No coordinates of any kind for a refused ring: never a zero-filled
      // quad as a stand-in. The reference frame may still be recorded, because
      // the frame the photo was measured in is a true fact even when the ring
      // is refused; what must never appear is a corner position.
      expect(step.fields.containsKey('quadCorners'), isFalse);
    });

    test('an out-of-frame proposal is refused by name', () {
      final outside = [
        Point2(-.1, .1),
        Point2(.9, .1),
        Point2(.9, .9),
        Point2(.1, .9),
      ];
      final step = _detection(
        _project([_oneDocument(null, suggested: outside)]),
      );
      expect(step.fields['quadStatus'], 'invalid');
      expect(step.fields['quadReason'], 'outOfBounds');
      expect(step.fields.containsKey('quadCorners'), isFalse);
    });

    test('the corner status never disagrees with the report verdict', () {
      // `_hasAcceptedBoundary` is the app's own definition of an accepted
      // boundary: a non-legacy producer plus a geometrically valid ring. It
      // does not consult the diagnostic sentences. The export must use the
      // SAME rule, so a reader can never see "accepted" beside `accepted:
      // false` (or the reverse) for one document.
      final quad = [
        Point2(.1, .1),
        Point2(.9, .1),
        Point2(.9, .9),
        Point2(.1, .9),
      ];
      final withDiagnostics = _detection(
        _project([
          _oneDocument(
            quad,
            diagnostics: const ['يلامس حافة الصورة'],
            trace: const ['review=touchesFrameEdge'],
          ),
        ]),
      );
      expect(withDiagnostics.fields['accepted'], isTrue);
      expect(withDiagnostics.fields['quadStatus'], 'accepted');

      final withoutPolygon = _detection(
        _project([
          _oneDocument(null, trace: const ['review=touchesFrameEdge']),
        ]),
      );
      expect(withoutPolygon.fields.containsKey('accepted'), isFalse);
      expect(withoutPolygon.fields['quadStatus'], 'none');
    });

    test('a legacy-import polygon is a region, not a detection', () {
      // Migration synthesizes a full-frame polygon for old records. Exporting
      // its four corners would report perfect corners nobody measured, so no
      // coordinates may be exported. It is a refusal with a reason -- the
      // record does carry a polygon -- and not the `none` "nothing was
      // produced" state, which would misdescribe the record.
      final full = [Point2(0, 0), Point2(1, 0), Point2(1, 1), Point2(0, 1)];
      final step = _detection(
        _project([_oneDocument(full, producer: 'legacy-import')]),
      );
      expect(step.fields['quadStatus'], 'invalid');
      expect(step.fields['quadReason'], 'notAuthorized');
      expect(step.fields.containsKey('quadCorners'), isFalse);
    });
  });

  group('a produced ring the app refused is never reported as absence', () {
    test('a three-point detection is a refusal, not "nothing produced"', () {
      // `DetectionRef` accepts any non-empty finite polygon, so a detector
      // that returned the wrong number of corners is a state this build can
      // hold. `none` means "no quadrilateral was produced"; reporting that
      // here would let a mis-shaped detection pass as "the detector found
      // nothing", which is the opposite conclusion.
      final step = _detection(
        _project([
          _record(
            id: 'd1',
            sides: [
              _side(
                polygon: [Point2(.1, .1), Point2(.9, .1), Point2(.9, .9)],
              ),
            ],
          ),
        ]),
      );
      expect(step.fields['quadStatus'], 'invalid');
      expect(step.fields['quadReason'], 'wrongPointCount');
      expect(step.fields.containsKey('quadCorners'), isFalse);
    });

    test('a five-point detection names its reason too', () {
      final step = _detection(
        _project([
          _record(
            id: 'd1',
            sides: [
              _side(
                polygon: [
                  Point2(.1, .1),
                  Point2(.9, .1),
                  Point2(.9, .9),
                  Point2(.1, .9),
                  Point2(.5, .5),
                ],
              ),
            ],
          ),
        ]),
      );
      expect(step.fields['quadStatus'], 'invalid');
      expect(step.fields['quadReason'], 'wrongPointCount');
      expect(step.fields.containsKey('quadCorners'), isFalse);
    });

    test('an out-of-bounds accepted-candidate names outOfBounds', () {
      // A four-point ring with a corner outside [0,1] must not be `none`
      // either: the detector produced geometry, and the refusal is geometric.
      final step = _detection(
        _project([
          _record(
            id: 'd1',
            sides: [
              _side(
                polygon: [
                  Point2(-.2, .1),
                  Point2(.9, .1),
                  Point2(.9, .9),
                  Point2(.1, .9),
                ],
              ),
            ],
          ),
        ]),
      );
      expect(step.fields['quadStatus'], 'invalid');
      expect(step.fields['quadReason'], 'outOfBounds');
      expect(step.fields.containsKey('quadCorners'), isFalse);
    });

    test('a refused polygon is not replaced by its review proposal', () {
      // A refused `polygon` plus a clean `suggestedPolygon` must still report
      // the refusal. Falling back to the suggestion would relabel a refused
      // detection as a usable one, which is exactly what the audit forbids.
      final step = _detection(
        _project([
          _record(
            id: 'd1',
            sides: [
              _side(
                polygon: [
                  Point2(.1, .1),
                  Point2(.9, .1),
                  Point2(.9, .9),
                ],
                suggested: [
                  Point2(.2, .2),
                  Point2(.8, .2),
                  Point2(.8, .8),
                  Point2(.2, .8),
                ],
              ),
            ],
          ),
        ]),
      );
      expect(step.fields['quadStatus'], 'invalid');
      expect(step.fields.containsKey('quadCorners'), isFalse);
    });

    test('a geometrically fine ring refused by the decision says so', () {
      // `legacy-import` is refused for provenance, not geometry. The reason
      // must describe that, and must never be invented as a geometry code.
      final step = _detection(
        _project([
          _oneDocument(
            [Point2(0, 0), Point2(1, 0), Point2(1, 1), Point2(0, 1)],
            producer: 'legacy-import',
          ),
        ]),
      );
      expect(step.fields['quadStatus'], 'invalid');
      expect(step.fields['quadReason'], 'notAuthorized');
      expect(step.fields.containsKey('quadCorners'), isFalse);
    });
  });

  group('no detection produces no coordinates', () {
    // A side may carry a detection result whose polygon is null: that is the
    // pipeline saying "no trustworthy boundary". It must be reported as
    // absence, never as a quad of zeros.
    test('a detection that produced no usable quad reports absence', () {
      final step = _detection(
        _project([
          _oneDocument(null, trace: const ['aspect=1.5']),
        ]),
      );
      expect(step.fields['quadStatus'], 'none');
      expect(step.fields.containsKey('quadCorners'), isFalse);
      expect(step.fields.containsKey('quadWidth'), isFalse);
      expect(step.fields.containsKey('quadHeight'), isFalse);
    });

    test('an image with no record at all carries no corner keys', () {
      final step = _detection(projectFixture());
      expect(step.fields.containsKey('quadStatus'), isFalse);
      expect(step.fields.containsKey('quadCorners'), isFalse);
    });

    test('a side with no detection carries no corner keys of its own', () {
      final project = _project([
        _record(
          id: 'd1',
          sides: [
            DocumentSide(
              id: 's1',
              side: SideKind.unknown,
              processedAsset: ProcessedAssetRef(
                workingPath: 'projects/project1/processed/s1/working.png',
                thumbnailPath: 'projects/project1/processed/s1/thumb.jpg',
                width: 400,
                height: 250,
              ),
            ),
          ],
        ),
      ]);
      final step = _detection(project);
      expect(step.fields.containsKey('quadStatus'), isFalse);
    });
  });

  group('several documents keep their own corners', () {
    test('each document gets its own block under its own id prefix', () {
      final first = [
        Point2(.05, .05),
        Point2(.45, .05),
        Point2(.45, .45),
        Point2(.05, .45),
      ];
      final second = [
        Point2(.55, .55),
        Point2(.95, .55),
        Point2(.95, .95),
        Point2(.55, .95),
      ];
      final step = _detection(
        _project([
          _oneDocument(first, id: 'd1', sideId: 's1'),
          _oneDocument(second, id: 'd2', sideId: 's2'),
        ]),
      );

      expect(step.fields['documents'], 2);
      expect(step.fields['d1_quadStatus'], 'accepted');
      expect(step.fields['d2_quadStatus'], 'accepted');
      expect(_corners(step.fields, 'd1_')[0], (.05, .05));
      expect(_corners(step.fields, 'd2_')[0], (.55, .55));
      // The two rings are not interchanged.
      expect(_corners(step.fields, 'd1_')[2], (.45, .45));
      expect(_corners(step.fields, 'd2_')[2], (.95, .95));
    });

    test('a two-sided document is numbered once, with side indices', () {
      final front = [
        Point2(.1, .1),
        Point2(.9, .1),
        Point2(.9, .5),
        Point2(.1, .5),
      ];
      final back = [
        Point2(.1, .5),
        Point2(.9, .5),
        Point2(.9, .9),
        Point2(.1, .9),
      ];
      final step = _detection(
        _project([
          _record(
            id: 'd1',
            sides: [
              _side(id: 's1', side: SideKind.front, polygon: front),
              _side(id: 's2', side: SideKind.back, polygon: back),
            ],
          ),
        ]),
      );

      // Same numbering as the rest of the report: d1 is the document, s1/s2
      // its sides. A per-side numbering would have produced d1_/d2_ here and
      // silently mislabelled the back as a second document.
      expect(step.fields['d1_s1_quadStatus'], 'accepted');
      expect(step.fields['d1_s2_quadStatus'], 'accepted');
      expect(_corners(step.fields, 'd1_s1_')[0], (.1, .1));
      expect(_corners(step.fields, 'd1_s2_')[3], (.1, .9));
      expect(step.fields.containsKey('d2_s1_quadStatus'), isFalse);
    });

    test('a document without a quad does not shift its neighbour prefix', () {
      final quad = [
        Point2(.6, .6),
        Point2(.9, .6),
        Point2(.9, .9),
        Point2(.6, .9),
      ];
      final step = _detection(
        _project([
          _record(
            id: 'd1',
            sides: [_side(id: 's1')],
          ),
          _oneDocument(quad, id: 'd2', sideId: 's2'),
        ]),
      );
      // d2 keeps the "2" it has in every other field of this report.
      expect(step.fields['d2_quadStatus'], 'accepted');
      expect(_corners(step.fields, 'd2_')[0], (.6, .6));
      expect(step.fields.containsKey('d1_quadStatus'), isFalse);
    });
  });

  group('the export leaks nothing and stays backward compatible', () {
    test('no recognized text, path or person data in the corner block', () {
      final quad = [
        Point2(.1, .1),
        Point2(.9, .1),
        Point2(.9, .9),
        Point2(.1, .9),
      ];
      final step = _detection(_project([_oneDocument(quad)]));
      for (final entry in step.fields.entries) {
        if (!entry.key.startsWith('quad')) continue;
        final value = entry.value;
        if (value is! String) continue;
        expect(value.contains('/'), isFalse, reason: entry.key);
        expect(value.contains('\\'), isFalse, reason: entry.key);
        expect(value.contains('.jpg'), isFalse, reason: entry.key);
        expect(value.contains('projects'), isFalse, reason: entry.key);
        expect(
          value.length,
          lessThanOrEqualTo(JourneyStep.maxFieldValueLength),
        );
      }
      // Producer is a bounded code, never a model path.
      expect(step.fields['quadSource'], 'cascade');
    });

    test('a file written before this field existed still reads', () {
      // A real pre-change entry: detection fields, no quad keys at all.
      final legacy = {
        'version': 1,
        'id': 'journey-0001-abcd',
        'batch': 'batch-0001',
        'project': {'id': 'p1', 'name': 'مشروع'},
        'image': 'ورقة.jpg',
        'started_utc': '2026-11-01T09:00:00.000Z',
        'steps': [
          {
            'stage': 'detection',
            'outcome': 'passed',
            'detail': 'حُفظت حدود مقبولة.',
            'fields': {'aspect': 1.59, 'accepted': true, 'reasons': 0},
          },
        ],
      };
      final journey = ImageJourney.fromJson(legacy);
      final step = journey.steps.single;
      expect(step.fields['aspect'], 1.59);
      expect(step.fields.containsKey('quadStatus'), isFalse);
      expect(step.fields.containsKey('quadCorners'), isFalse);
      // Re-serializing an old entry does not invent corner keys.
      final again = step.toJson();
      expect((again['fields']! as Map).containsKey('quadStatus'), isFalse);
    });

    test('the corner block survives a save and restore unchanged', () {
      final quad = [
        Point2(.1049, .2013),
        Point2(.8802, .1507),
        Point2(.9311, .8404),
        Point2(.0823, .7911),
      ];
      final journey = buildImageJourneys(
        batchId: 'batch-0001',
        startedAt: DateTime.utc(2026, 11, 22, 10),
        images: const [ImportedImageFact(name: 'ورقة.jpg', assetId: 'a1')],
        project: _project([_oneDocument(quad)]),
      ).single;

      final encoded = jsonEncode(journey.toJson());
      final restored = ImageJourney.fromJson(jsonDecode(encoded));
      expect(restored.toJson(), journey.toJson());

      final step = restored.steps.firstWhere(
        (s) => s.stage == JourneyStage.detection,
      );
      expect(_corners(step.fields)[1], (.8802, .1507));
    });
  });

  group('the export cannot change what the pipeline decided', () {
    test('the exported ring is the detector polygon, point for point', () {
      // Guards against rounding the geometry itself, reordering it into a
      // different ring, or substituting the warped crop's corners.
      final quad = [
        Point2(.33, .44),
        Point2(.77, .41),
        Point2(.81, .88),
        Point2(.29, .91),
      ];
      final step = _detection(
        _project([
          _record(
            id: 'd1',
            sides: [
              _side(
                polygon: quad,
                // The warp output is a DIFFERENT ring; it must not leak in.
                processedCorners: [
                  Point2(0, 0),
                  Point2(1, 0),
                  Point2(1, 1),
                  Point2(0, 1),
                ],
              ),
            ],
          ),
        ]),
      );
      final ring = _corners(step.fields);
      for (var i = 0; i < 4; i++) {
        expect(ring[i].$1, closeTo(quad[i].x, 1e-9));
        expect(ring[i].$2, closeTo(quad[i].y, 1e-9));
      }
    });

    test('adding corners leaves the existing detection fields untouched', () {
      final quad = [
        Point2(.1, .1),
        Point2(.9, .1),
        Point2(.9, .9),
        Point2(.1, .9),
      ];
      final step = _detection(
        _project([
          _record(
            id: 'd1',
            sides: [
              _side(polygon: quad, trace: const ['aspect=1.5', 'area=0.05']),
            ],
          ),
        ]),
      );
      expect(step.fields['aspect'], 1.5);
      expect(step.fields['area'], 0.05);
      expect(step.fields['accepted'], isTrue);
      // The step's own verdict is unchanged by having exported corners.
      expect(step.outcome, JourneyOutcome.passed);
    });

    test('a twelve-document entry still fits inside the journal entry cap', () {
      final fields = _detection(
        _project([
          for (var n = 1; n <= 12; n++)
            _record(
              id: 'd$n',
              sides: [
                _side(
                  id: 's$n',
                  polygon: [
                    Point2(.1, .1),
                    Point2(.9, .1),
                    Point2(.9, .9),
                    Point2(.1, .9),
                  ],
                  trace: const ['aspect=1.5', 'area=0.05', 'geometry=0.9'],
                ),
              ],
            ),
        ]),
      ).fields;

      final bytes = utf8.encode(jsonEncode({'fields': fields})).length;
      expect(bytes, lessThan(8192));
      // Every document still has its own corners.
      for (var n = 1; n <= 12; n++) {
        expect(fields['d${n}_quadStatus'], 'accepted', reason: 'd$n');
      }
    });

    test('twelve documents with two quads each keep all 144 corner keys', () {
      // The old 96-key budget overflowed at nine documents and returned `{}`,
      // silently turning twelve MEASURED documents into "no corner data".
      // 12 documents x 2 sides x 6 keys = 144 is the real worst case, and its
      // measured payload is 7,866 bytes -- inside the 8,192-byte entry cap.
      final fields = _detection(
        _project([
          for (var n = 1; n <= 12; n++)
            _record(
              id: 'd$n',
              sides: [
                for (var side = 1; side <= 2; side++)
                  _side(
                    id: 's$n-$side',
                    side: side == 1 ? SideKind.front : SideKind.back,
                    polygon: [
                      Point2(.1 + side * .01, .1),
                      Point2(.9, .1 + side * .01),
                      Point2(.9, .9),
                      Point2(.1, .9),
                    ],
                    trace: const ['aspect=1.5', 'area=0.05'],
                  ),
              ],
            ),
        ]),
      ).fields;

      var quads = 0;
      for (var n = 1; n <= 12; n++) {
        for (var side = 1; side <= 2; side++) {
          final prefix = 'd${n}_s${side}_';
          expect(
            fields['${prefix}quadStatus'],
            'accepted',
            reason: 'd$n side $side',
          );
          expect(fields['${prefix}quadSpace'], 'originalNorm');
          expect(fields.keys.contains('${prefix}quadCorners'), isTrue);
          quads++;
        }
      }
      expect(quads, 24);
      expect(
        fields.containsKey('quadOverflowDocuments'),
        isFalse,
        reason: 'nothing overflowed, so nothing may claim it did',
      );
      final bytes = utf8.encode(jsonEncode({'fields': fields})).length;
      expect(bytes, lessThan(8192));
    });

    test('an overflowing frame keeps what was measured and states the rest',
        () {
      // Past the ceiling the export must not fall silent about measured
      // documents: the blocks already accrued survive, and the overflow is
      // named once. 13 documents with two sides each is the first frame that
      // exceeds 144 keys.
      final fields = _detection(
        _project([
          for (var n = 1; n <= 13; n++)
            _record(
              id: 'd$n',
              sides: [
                for (var side = 1; side <= 2; side++)
                  _side(
                    id: 's$n-$side',
                    polygon: [
                      Point2(.1, .1),
                      Point2(.9, .1),
                      Point2(.9, .9),
                      Point2(.1, .9),
                    ],
                    trace: const ['aspect=1.5', 'area=0.05'],
                  ),
              ],
            ),
        ]),
      ).fields;

      // Twelve documents fit (144 keys); the thirteenth is the overflow.
      for (var n = 1; n <= 12; n++) {
        expect(fields['d${n}_s1_quadStatus'], 'accepted', reason: 'd$n');
        expect(fields['d${n}_s2_quadStatus'], 'accepted', reason: 'd$n');
      }
      expect(fields['quadOverflowDocuments'], 1);
      expect(fields.containsKey('d13_s1_quadStatus'), isFalse);
    });
  });
}
