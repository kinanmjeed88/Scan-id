import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/application/image_journey_report.dart';
import 'package:scan_id/application/journey_export.dart';
import 'package:scan_id/domain/geometry.dart';
import 'package:scan_id/domain/image_journey.dart';
import 'package:scan_id/domain/project.dart';
import 'package:scan_id/domain/recognition.dart';
import 'package:scan_id/imaging/docaligner_model.dart';
import 'package:scan_id/imaging/docquad_model.dart';

import '../fixtures.dart';

// Audit of the journey report.
//
//  1. It never attributes one image's facts to another: two images picked in
//     one run, with different sizes, detector scores and decisions, are each
//     described by their own record.
//  2. Nor one document's facts to another document of the same image: a photo
//     that held several documents keeps each one's measurements and verdict
//     under its own keys.
//  3. The two shipped detectors are filed under their own names. The traces
//     here are built from the ids the models themselves declare.
//  4. It can always be built. The report is a courtesy filed after the import
//     has been committed, and the journal validates what it stores (one-line
//     names, bounded lengths). A picked file whose name the journal cannot
//     hold must therefore be DESCRIBED in a form it can hold, never thrown:
//     an exception here would surface as a failed intake although the images
//     were imported.
//
// Pure data: no image, no recognized text, no personal data.

ImageAsset _asset(String id, int width, int height, {String? derivedFrom}) =>
    ImageAsset(
      id: id,
      name: '$id.jpg',
      originalPath: 'projects/project1/assets/$id/original.jpg',
      workingPath: 'projects/project1/assets/$id/working.png',
      thumbnailPath: 'projects/project1/assets/$id/thumb.jpg',
      width: width,
      height: height,
      derivedFrom: derivedFrom,
    );

DocumentRecord _record({
  required String id,
  required String source,
  required List<String> trace,
  List<String> diagnostics = const [],
  (int, int)? warpedTo,
  (int, int) processed = (400, 250),
  bool suggested = false,
}) {
  final quad = [Point2(.1, .1), Point2(.9, .1), Point2(.9, .9), Point2(.1, .9)];
  return DocumentRecord(
    id: id,
    sourceImageId: source,
    sides: [
      DocumentSide(
        id: 'side-$id',
        side: SideKind.unknown,
        processedAsset: ProcessedAssetRef(
          workingPath: 'projects/project1/processed/$id/working.png',
          thumbnailPath: 'projects/project1/processed/$id/thumb.jpg',
          width: warpedTo?.$1 ?? processed.$1,
          height: warpedTo?.$2 ?? processed.$2,
          outputWidth: warpedTo?.$1,
          outputHeight: warpedTo?.$2,
          corners: warpedTo == null ? null : quad,
        ),
        detection: DetectionRef(
          detectionId: 'det-$id',
          producer: 'cascade',
          version: 'v1',
          polygon: warpedTo == null ? null : quad,
          suggestedPolygon: suggested ? quad : null,
          detectionTrace: trace,
          boundaryDiagnostics: diagnostics,
        ),
      ),
    ],
    pairing: PairingState.single,
    provenance: Provenance(
      sourceImageId: source,
      detectionIds: ['det-$id'],
      processedAssetVersion: 'smart-1',
      pipelineVersion: 'pipeline-v1',
    ),
  );
}

DocumentItem _item(String id, String assetId, String documentId) =>
    DocumentItem(
      id: id,
      assetId: assetId,
      documentId: documentId,
      sideId: 'side-$documentId',
      x: 20,
      y: 25,
      width: 90,
      height: 55,
    );

/// Two images of one run, as the project holds them afterwards:
///
/// * `a1` was copied at 399×501 and warped to 342×215 (its asset now carries
///   the crop's size under the same id);
/// * `a2` was copied at 422×303 and its proposal was refused.
Project _twoImages() => projectFixture().copyWith(
  assets: [_asset('a1', 342, 215), _asset('a2', 422, 303)],
  documents: [
    _record(
      id: 'd1',
      source: 'a1',
      warpedTo: (342, 215),
      trace: const [
        'model=$docQuadNetModelId;outcome=proposal;confidence=0.913',
        'model=$docAlignerModelId;outcome=proposal;confidence=0.877',
        'disagreement=0.013',
        'aspect=1.59',
        'area=0.37',
        'geometry=0.95',
      ],
    ),
    _record(
      id: 'd2',
      source: 'a2',
      processed: (422, 303),
      trace: const [
        'model=$docQuadNetModelId;outcome=proposal;confidence=0.211',
        'model=$docAlignerModelId;outcome=noQuad',
        'aspect=1.69',
        'area=0.057',
        'review=excludesDocumentText',
      ],
      diagnostics: const ['الحدود المقترحة تترك نص المستند خارجها'],
    ),
  ],
  items: [_item('i1', 'a1', 'd1'), _item('i2', 'a2', 'd2')],
);

const _first = ImportedImageFact(
  name: 'أولى.jpg',
  assetId: 'a1',
  copyDurationMs: 120,
  copiedWidth: 399,
  copiedHeight: 501,
);

const _second = ImportedImageFact(
  name: 'ثانية.jpg',
  assetId: 'a2',
  copyDurationMs: 95,
  copiedWidth: 422,
  copiedHeight: 303,
);

List<ImageJourney> _build(
  List<ImportedImageFact> images, {
  Project? project,
  int? savedRevision = 7,
}) => buildImageJourneys(
  batchId: 'batch-0001',
  project: project ?? _twoImages(),
  images: images,
  startedAt: DateTime.utc(2026, 11, 13, 9),
  savedRevision: savedRevision,
);

JourneyStep _step(ImageJourney journey, JourneyStage stage) =>
    journey.steps.firstWhere((step) => step.stage == stage);

void main() {
  group('two images of one run are never mixed', () {
    test('each copy step states its own copy, not the other image and not '
        'the crop', () {
      final journeys = _build(const [_first, _second]);
      final a = _step(journeys[0], JourneyStage.copy);
      final b = _step(journeys[1], JourneyStage.copy);

      expect(a.fields['copiedWidth'], 399);
      expect(a.fields['copiedHeight'], 501);
      expect(a.detail, contains('399×501'));
      expect(a.detail, isNot(contains('342')));
      expect(a.durationMs, 120);

      expect(b.fields['copiedWidth'], 422);
      expect(b.fields['copiedHeight'], 303);
      expect(b.detail, contains('422×303'));
      expect(b.durationMs, 95);
    });

    test('each detection step carries its own detector numbers and '
        'decision', () {
      final journeys = _build(const [_first, _second]);
      final a = _step(journeys[0], JourneyStage.detection);
      final b = _step(journeys[1], JourneyStage.detection);

      expect(a.outcome, JourneyOutcome.passed);
      expect(a.fields['docquadnet_confidence'], .913);
      expect(a.fields['docaligner_outcome'], 'proposal');
      expect(a.fields['docaligner_confidence'], .877);
      expect(a.fields['disagreement'], .013);
      expect(a.fields['accepted'], isTrue);
      expect(a.fields.keys.where((key) => key.startsWith('review_')), isEmpty);

      expect(b.outcome, JourneyOutcome.review);
      expect(b.fields['docquadnet_confidence'], .211);
      expect(b.fields['docaligner_outcome'], 'noQuad');
      expect(b.fields.containsKey('docaligner_confidence'), isFalse);
      expect(b.fields.containsKey('disagreement'), isFalse);
      expect(b.fields.containsKey('accepted'), isFalse);
      expect(b.fields['review_1'], 'excludesDocumentText');
    });

    test('each crop step states what happened to its own image', () {
      final journeys = _build(const [_first, _second]);
      final a = _step(journeys[0], JourneyStage.crop);
      final b = _step(journeys[1], JourneyStage.crop);

      expect(a.outcome, JourneyOutcome.passed);
      expect(a.fields['outputWidth'], 342);
      expect(a.fields['outputHeight'], 215);

      expect(b.outcome, JourneyOutcome.review);
      expect(b.fields, isEmpty);
      expect(b.detail, contains('لم يُقصّ تلقائياً'));
      expect(b.detail, isNot(contains('342')));
    });

    test('the pick order decides the report order, the asset decides the '
        'content', () {
      final forward = _build(const [_first, _second]);
      final reversed = _build(const [_second, _first]);

      expect(forward.map((entry) => entry.imageName), [
        'أولى.jpg',
        'ثانية.jpg',
      ]);
      expect(reversed.map((entry) => entry.imageName), [
        'ثانية.jpg',
        'أولى.jpg',
      ]);
      // The same image yields the same entry wherever it was picked, apart
      // from the batch-level save line that only the last image carries.
      Map<String, Object?> content(ImageJourney journey) => {
        'id': journey.id,
        'image': journey.imageName,
        'steps': [
          for (final step in journey.steps)
            if (step.stage != JourneyStage.save) step.toJson(),
        ],
      };

      expect(content(reversed[1]), content(forward[0]));
      expect(content(reversed[0]), content(forward[1]));
      expect(forward[0].id, isNot(forward[1].id));
      expect(forward[0].id, contains('a1'));
      expect(forward[1].id, contains('a2'));
    });

    test('a failed copy beside a successful one reports nothing of its '
        'neighbour', () {
      const failed = ImportedImageFact(
        name: 'تالفة.jpg',
        failureMessage: 'تعذر قراءة الملف.',
      );
      final journeys = _build(const [failed, _first]);
      final lost = journeys[0];

      expect(_step(lost, JourneyStage.copy).outcome, JourneyOutcome.blocked);
      expect(_step(lost, JourneyStage.copy).fields, isEmpty);
      expect(
        _step(lost, JourneyStage.detection).outcome,
        JourneyOutcome.skipped,
      );
      expect(jsonEncode(lost.toJson()), isNot(contains('399')));
      expect(jsonEncode(lost.toJson()), isNot(contains('0.913')));
      expect(_step(journeys[1], JourneyStage.copy).fields['copiedWidth'], 399);
    });

    test('regions cut from one image belong to that image only', () {
      final project = projectFixture().copyWith(
        assets: [
          _asset('a1', 1200, 800),
          _asset('a1-r1', 500, 320, derivedFrom: 'a1'),
          _asset('a2', 422, 303),
        ],
        documents: [
          _record(
            id: 'd1',
            source: 'a1',
            processed: (500, 320),
            trace: const [
              'model=$docQuadNetModelId;outcome=proposal;confidence=0.7',
            ],
          ),
        ],
        items: [
          _item('i1', 'a1-r1', 'd1'),
          DocumentItem(
            id: 'i2',
            assetId: 'a2',
            x: 20,
            y: 100,
            width: 90,
            height: 55,
          ),
        ],
      );
      const source = ImportedImageFact(
        name: 'صفحة.jpg',
        assetId: 'a1',
        copiedWidth: 1200,
        copiedHeight: 800,
      );
      final journeys = _build(const [source, _second], project: project);

      expect(
        _step(
          journeys[0],
          JourneyStage.detection,
        ).fields['docquadnet_confidence'],
        .7,
      );
      // The second image has no record of its own: nothing of the first
      // image's detection is attributed to it.
      expect(
        _step(journeys[1], JourneyStage.detection).outcome,
        JourneyOutcome.blocked,
      );
      expect(_step(journeys[1], JourneyStage.detection).fields, isEmpty);
    });
  });

  group('the shipped detectors are filed under their own names', () {
    test('the ids the models declare are the ones the report knows', () {
      // The report matches by family. If a model is ever renamed out of its
      // family, this fails here instead of silently moving its facts.
      expect(docQuadNetModelId.toLowerCase(), contains('docquad'));
      expect(docAlignerModelId.toLowerCase(), contains('docaligner'));
    });

    test('each model has its own keys and nothing is filed generically', () {
      final detection = _step(
        _build(const [_first]).single,
        JourneyStage.detection,
      );

      expect(detection.fields['docquadnet_outcome'], 'proposal');
      expect(detection.fields['docquadnet_confidence'], .913);
      expect(detection.fields['docaligner_outcome'], 'proposal');
      expect(detection.fields['docaligner_confidence'], .877);
      expect(
        detection.fields.keys.where((key) => key.startsWith('detector_')),
        isEmpty,
      );
      expect(detection.detail, contains('DocQuadNet'));
      expect(detection.detail, contains('DocAligner'));
    });

    test('repeated and unknown detector runs retain their own evidence', () {
      final project = projectFixture().copyWith(
        assets: [_asset('a1', 400, 250)],
        documents: [
          _record(id: 'd1', source: 'a1', trace: const [
            'model=DocQuadNet-v1;outcome=proposal;confidence=0.900',
            'model=DocQuadNet-v2;outcome=noQuad',
            'model=future-a;outcome=proposal;confidence=0.800',
            'model=future-b;outcome=noQuad',
          ]),
        ],
        items: [_item('i1', 'a1', 'd1')],
      );
      final detection = _step(
        _build(const [ImportedImageFact(name: 'صورة.jpg', assetId: 'a1')],
            project: project).single,
        JourneyStage.detection,
      );
      expect(detection.fields['docquadnet_outcome'], 'proposal');
      expect(detection.fields['docquadnet_confidence'], .9);
      expect(detection.fields['run2_model'], 'DocQuadNet-v2');
      expect(detection.fields['run2_outcome'], 'noQuad');
      expect(detection.fields.containsKey('run2_confidence'), isFalse);
      expect(detection.fields['run3_model'], 'future-a');
      expect(detection.fields['run3_confidence'], .8);
      expect(detection.fields['run4_model'], 'future-b');
      expect(detection.fields['run4_outcome'], 'noQuad');
      expect(detection.fields.containsKey('run4_confidence'), isFalse);
    });

    test('a model this build does not name keeps the generic slot', () {
      final project = projectFixture().copyWith(
        assets: [_asset('a1', 400, 250)],
        documents: [
          _record(
            id: 'd1',
            source: 'a1',
            trace: const ['model=future-net-2;outcome=noQuad'],
          ),
        ],
        items: [_item('i1', 'a1', 'd1')],
      );
      final detection = _step(
        _build(const [
          ImportedImageFact(name: 'صورة.jpg', assetId: 'a1'),
        ], project: project).single,
        JourneyStage.detection,
      );
      expect(detection.fields['detector_outcome'], 'noQuad');
    });
  });

  group('several documents in one image keep their own facts', () {
    // One photo, two documents: the first was accepted and matches its
    // catalog shape, the second touches the frame edge and was refused.
    Project twoDocuments() => projectFixture().copyWith(
      assets: [
        _asset('a1', 1200, 800),
        _asset('a1-r1', 500, 315, derivedFrom: 'a1'),
        _asset('a1-r2', 400, 600, derivedFrom: 'a1'),
      ],
      documents: [
        _record(
          id: 'd1',
          source: 'a1',
          warpedTo: (500, 315),
          trace: const [
            'aspect=1.586',
            'area=0.210',
            'geometry=0.950',
            'catalogShape=match',
          ],
        ),
        _record(
          id: 'd2',
          source: 'a1',
          processed: (400, 600),
          trace: const [
            'aspect=0.700',
            'area=0.180',
            'geometry=0.400',
            'review=touchesFrameEdge',
          ],
          diagnostics: const ['يلامس حافة الصورة'],
        ),
      ],
      items: [_item('i1', 'a1-r1', 'd1'), _item('i2', 'a1-r2', 'd2')],
    );

    JourneyStep detection() => _step(
      _build(const [
        ImportedImageFact(
          name: 'صفحة.jpg',
          assetId: 'a1',
          copiedWidth: 1200,
          copiedHeight: 800,
        ),
      ], project: twoDocuments()).single,
      JourneyStage.detection,
    );

    test(
      'a refused document keeps the shared detection and crop in review',
      () {
        final journey = _build(const [
          ImportedImageFact(name: 'صفحة.jpg', assetId: 'a1'),
        ], project: twoDocuments()).single;
        expect(
          _step(journey, JourneyStage.detection).outcome,
          JourneyOutcome.review,
        );
        expect(
          _step(journey, JourneyStage.crop).outcome,
          JourneyOutcome.review,
        );
        expect(journey.verdict, JourneyOutcome.review);
      },
    );

    test('each document carries its own measurements and verdict', () {
      final fields = detection().fields;

      expect(fields['documents'], 2);
      expect(fields['acceptedDocuments'], 1);

      expect(fields['d1_aspect'], 1.586);
      expect(fields['d1_area'], .21);
      expect(fields['d1_geometry'], .95);
      expect(fields['d1_catalogShape'], 'match');
      expect(fields['d1_accepted'], isTrue);
      expect(fields.containsKey('d1_review_1'), isFalse);
      expect(fields.containsKey('d1_reasons'), isFalse);

      expect(fields['d2_aspect'], .7);
      expect(fields['d2_area'], .18);
      expect(fields['d2_geometry'], .4);
      expect(fields['d2_review_1'], 'touchesFrameEdge');
      expect(fields['d2_reasons'], 1);
      expect(fields.containsKey('d2_accepted'), isFalse);
      expect(fields.containsKey('d2_catalogShape'), isFalse);
    });

    test('no shared key states a decision that was never taken', () {
      // Before this was pinned the step read: accepted, shape matches the
      // catalog, aspect 0.70, touches the frame edge. That is the verdict of
      // the first document beside the measurements of the second.
      final fields = detection().fields;
      for (final key in const [
        'aspect',
        'area',
        'geometry',
        'catalogShape',
        'review_1',
        'accepted',
        'reasons',
      ]) {
        expect(fields.containsKey(key), isFalse, reason: key);
      }
    });

    test('the sentence says how many documents and names each one', () {
      final detail = detection().detail;
      expect(detail, contains('2 مستندات في الصورة الواحدة'));
      expect(detail, contains('1 منها بحدود مقبولة'));
      expect(detail, contains('المستند 1:'));
      expect(detail, contains('المستند 2:'));
      expect(detail.indexOf('المستند 1:'), lessThan(detail.indexOf('1.59:1')));
      expect(detail.indexOf('المستند 2:'), lessThan(detail.indexOf('0.70:1')));
    });

    test('twelve documents, the most one photo yields, still fit an entry', () {
      final project = projectFixture().copyWith(
        assets: [
          _asset('a1', 1200, 800),
          for (var n = 1; n <= 12; n++)
            _asset('a1-r$n', 300, 200, derivedFrom: 'a1'),
        ],
        documents: [
          for (var n = 1; n <= 12; n++)
            _record(
              id: 'd$n',
              source: 'a1',
              processed: (300, 200),
              trace: [
                'model=$docQuadNetModelId;outcome=proposal;confidence=0.5',
                'model=$docAlignerModelId;outcome=proposal;confidence=0.5',
                'disagreement=0.01',
                'aspect=1.5',
                'area=0.05',
                'geometry=0.9',
                'catalogAspect=1.586',
                'catalogShape=mismatch',
                'review=touchesFrameEdge',
                'review=modelNotCorroborated',
              ],
              diagnostics: const ['يلامس حافة الصورة'],
            ),
        ],
        items: [
          for (var n = 1; n <= 12; n++)
            DocumentItem(
              id: 'i$n',
              assetId: 'a1-r$n',
              documentId: 'd$n',
              sideId: 'side-d$n',
              x: 10,
              y: 10.0 + n,
              width: 60,
              height: 40,
            ),
        ],
      );
      final journey = _build(const [
        ImportedImageFact(name: 'صفحة.jpg', assetId: 'a1'),
      ], project: project).single;
      final step = _step(journey, JourneyStage.detection);

      expect(step.fields['documents'], 12);
      expect(step.fields['d12_docquadnet_confidence'], .5);
      expect(step.fields['d12_review_2'], 'modelNotCorroborated');
      expect(step.detail.length, lessThanOrEqualTo(240));
      // The entry survives the journal's own encoding and validation.
      final reread = ImageJourney.fromJson(
        jsonDecode(jsonEncode(journey.toJson())),
      );
      expect(reread.toJson(), journey.toJson());
      expect(utf8.encode(jsonEncode(journey.toJson())).length, lessThan(8192));
    });

    test('an image with one document keeps the unprefixed keys', () {
      final fields = _step(
        _build(const [_first]).single,
        JourneyStage.detection,
      ).fields;
      expect(fields['aspect'], 1.59);
      expect(fields['accepted'], isTrue);
      expect(fields.containsKey('documents'), isFalse);
      expect(fields.keys.where((key) => key.startsWith('d1_')), isEmpty);
    });
  });

  group('the report can always be built', () {
    ImageJourney only(String name, {Project? project}) => _build([
      ImportedImageFact(name: name, failureMessage: 'تعذر قراءة الملف.'),
    ], project: project).single;

    test('a name longer than the journal holds is shortened, not thrown', () {
      final journey = only('${'ط' * 300}.jpg');

      expect(journey.imageName.length, lessThanOrEqualTo(200));
      expect(journey.imageName, startsWith('طططط'));
      expect(journey.imageName, endsWith('…'));
    });

    test('a name at the limit is kept exactly', () {
      final name = '${'a' * 196}.jpg';
      expect(name.length, 200);
      expect(only(name).imageName, name);
    });

    test('line breaks and tabs in a name become spaces', () {
      final journey = only('صورة\r\nثانية\tهنا.jpg');

      expect(journey.imageName, 'صورة ثانية هنا.jpg');
    });

    test('an empty or blank name gets a fixed placeholder', () {
      expect(only('').imageName, 'صورة بلا اسم');
      expect(only('  \n ').imageName, 'صورة بلا اسم');
    });

    test('a project name with a line break does not break the report', () {
      final project = projectFixture().copyWith(name: 'عائلة\nفلان');
      final journey = only('صورة.jpg', project: project);

      expect(journey.projectName, 'عائلة فلان');
      expect(_step(journey, JourneyStage.selection).detail, contains('عائلة'));
      expect(
        _step(journey, JourneyStage.selection).detail,
        isNot(contains('\n')),
      );
    });

    test('whatever the names, the entries are ones the journal accepts', () {
      final project = projectFixture().copyWith(name: '${'م' * 150}\n\r');
      final journeys = _build([
        ImportedImageFact(name: 'ن' * 400, failureMessage: 'تعذر.'),
        const ImportedImageFact(name: '\n', failureMessage: 'تعذر.'),
        const ImportedImageFact(name: 'a\u0000b\u2028c\u2029d.jpg'),
        _first,
      ], project: project);

      expect(journeys, hasLength(4));
      // What the store and the export do with every entry.
      final document = encodeJourneyExport(
        journeys,
        exportedAt: DateTime.utc(2026, 11, 13),
      );
      final decoded = jsonDecode(document) as Map<String, Object?>;
      final reread = [
        for (final entry in decoded['journeys']! as List<Object?>)
          ImageJourney.fromJson(entry),
      ];
      expect(reread.map((entry) => entry.toJson()).toList(), [
        for (final entry in journeys) entry.toJson(),
      ]);
      for (final entry in reread) {
        expect(entry.imageName, isNot(contains('\n')));
        expect(entry.imageName, isNot(contains('\u0000')));
        expect(entry.imageName, isNot(contains('\u2028')));
      }
    });

    test('a name is never cut through the middle of a character', () {
      // Every emoji is two UTF-16 units; the cut lands inside one of them.
      final journey = only('${'a' * 198}😀😀😀.jpg');

      expect(journey.imageName.length, lessThanOrEqualTo(200));
      expect(journey.imageName, endsWith('…'));
      // Encodable and decodable without a replacement character.
      final reread = utf8.decode(utf8.encode(journey.imageName));
      expect(reread, journey.imageName);
      expect(reread, isNot(contains('\uFFFD')));
    });

    test('detector codes that say nothing in words still yield a step', () {
      final project = projectFixture().copyWith(
        assets: [_asset('a1', 400, 250)],
        documents: [
          _record(
            id: 'd1',
            source: 'a1',
            trace: const ['catalogAspect=1.586', 'futureCode=7'],
          ),
        ],
        items: [_item('i1', 'a1', 'd1')],
      );
      final journey = _build(const [
        ImportedImageFact(name: 'صورة.jpg', assetId: 'a1'),
      ], project: project).single;
      final detection = _step(journey, JourneyStage.detection);

      expect(detection.outcome, JourneyOutcome.review);
      expect(detection.detail, isNotEmpty);
      expect(detection.fields['catalogAspect'], 1.586);
      expect(detection.fields.containsKey('futureCode'), isFalse);
    });

    test('two unnamed images of one run still get distinct entries', () {
      final journeys = _build(const [
        ImportedImageFact(name: '', failureMessage: 'تعذر.'),
        ImportedImageFact(name: '', failureMessage: 'تعذر.'),
      ]);
      expect(journeys.map((entry) => entry.id).toSet(), hasLength(2));
    });
  });
}
