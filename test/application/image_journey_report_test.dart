import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/application/image_journey_report.dart';
import 'package:scan_id/domain/document_kind.dart';
import 'package:scan_id/domain/geometry.dart';
import 'package:scan_id/domain/image_journey.dart';
import 'package:scan_id/domain/project.dart';
import 'package:scan_id/domain/recognition.dart';

ImageAsset assetNamed(
  String id,
  String name, {
  String? derivedFrom,
  String? workingPath,
}) => ImageAsset(
  id: id,
  name: name,
  derivedFrom: derivedFrom,
  originalPath: 'projects/project1/assets/$id/original.png',
  workingPath: workingPath ?? 'projects/project1/assets/$id/working.png',
  thumbnailPath: 'projects/project1/assets/$id/thumb.jpg',
  width: 1200,
  height: 1600,
);

DocumentSide side({
  String id = 's1',
  double? confidence = 0.82,
  List<String> diagnostics = const [],
  List<String> trace = const [],
  bool suggestion = false,
  bool cropped = true,
  bool accepted = true,
  String producer = 'docquad',
  List<Point2>? polygon,
  String? processedPath,
}) => DocumentSide(
  id: id,
  side: SideKind.unknown,
  processedAsset: ProcessedAssetRef(
    workingPath: processedPath ?? 'projects/project1/processed/$id.png',
    thumbnailPath: 'projects/project1/processed/$id-thumb.jpg',
    width: 400,
    height: 250,
    outputWidth: cropped ? 1011 : null,
    outputHeight: cropped ? 638 : null,
    corners: cropped
        ? [Point2(0, 0), Point2(1, 0), Point2(1, 1), Point2(0, 1)]
        : null,
  ),
  detection: DetectionRef(
    detectionId: 'det-$id',
    producer: producer,
    version: 'v1',
    detectionConfidence: confidence == null
        ? null
        : Confidence(value: confidence),
    boundaryDiagnostics: diagnostics,
    detectionTrace: trace,
    polygon:
        polygon ??
        (accepted && !suggestion && diagnostics.isEmpty
            ? [Point2(0, 0), Point2(1, 0), Point2(1, 1), Point2(0, 1)]
            : null),
    suggestedPolygon: suggestion
        ? [Point2(0.1, 0.1), Point2(0.9, 0.9), Point2(0.2, 0.8), Point2(0, 1)]
        : null,
  ),
);

DocumentRecord record({
  String id = 'd1',
  String source = 'a1',
  DocumentSide? documentSide,
  RecognitionResult? recognition,
}) => DocumentRecord(
  id: id,
  sourceImageId: source,
  sides: [documentSide ?? side()],
  pairing: PairingState.single,
  recognition: recognition,
  provenance: Provenance(
    sourceImageId: source,
    detectionIds: const ['det-s1'],
    processedAssetVersion: 'smart-1',
    pipelineVersion: 'smart-1',
  ),
);

RecognitionResult recognized({
  DocumentKind kind = DocumentKind.unifiedNationalId,
  RecognitionStatus status = RecognitionStatus.recognized,
  double? ocr = 0.9,
  double? classification = 0.82,
  List<RecognitionEvidence> evidence = const [],
}) => RecognitionResult(
  documentKind: kind,
  status: status,
  confidences: ConfidenceSet(
    ocr: ocr == null ? null : Confidence(value: ocr),
    classification: classification == null
        ? null
        : Confidence(value: classification),
  ),
  evidence: evidence,
  preset: const PresetSelection.resolved('unified-national-id'),
);

DocumentItem placedItem({
  String id = 'i1',
  String assetId = 'a1',
  int? pageIndex = 0,
  bool sizeConfirmed = true,
  DocumentKind kind = DocumentKind.unifiedNationalId,
  String? documentId,
}) => DocumentItem(
  id: id,
  assetId: assetId,
  x: 20,
  y: 20,
  width: 85.6,
  height: 53.98,
  pageIndex: pageIndex,
  sizeConfirmed: sizeConfirmed,
  documentKind: kind,
  documentId: documentId,
);

Project projectWith({
  List<ImageAsset> assets = const [],
  List<DocumentItem> items = const [],
  List<DocumentRecord> documents = const [],
}) => Project(
  id: 'project1',
  name: 'مستمسكات العائلة',
  createdAt: DateTime.utc(2026, 10, 6),
  updatedAt: DateTime.utc(2026, 10, 6),
  revision: 7,
  assets: assets,
  items: items,
  documents: documents,
);

/// One picked source, so a test only writes what it is about.
List<ImportedImageFact> picked(
  String name, {
  String? assetId,
  String? failure,
}) => [
  ImportedImageFact(name: name, assetId: assetId, failureMessage: failure),
];

List<ImageJourney> build({
  required Project project,
  required List<ImportedImageFact> images,
  int? revision = 7,
}) => buildImageJourneys(
  batchId: 'batch-0001',
  project: project,
  images: images,
  startedAt: DateTime.utc(2026, 11, 9, 9),
  savedRevision: revision,
);

Map<JourneyStage, JourneyStep> byStage(ImageJourney journey) => {
  for (final step in journey.steps) step.stage: step,
};

void main() {
  group('journey report', () {
    test('a confidence without an accepted polygon stays in review', () {
      for (final traces in [
        <String>[],
        <String>['aspect=1.5'],
      ]) {
        final project = projectWith(
          assets: [assetNamed('a1', 'source.jpg')],
          documents: [
            record(documentSide: side(accepted: false, trace: traces)),
          ],
          items: [placedItem(documentId: 'd1')],
        );
        final journey = build(
          project: project,
          images: picked('source.jpg', assetId: 'a1'),
        ).single;
        expect(
          byStage(journey)[JourneyStage.detection]!.outcome,
          JourneyOutcome.review,
        );
      }
    });

    test('a legacy synthetic frame does not claim detector success', () {
      final project = projectWith(
        assets: [assetNamed('a1', 'source.jpg')],
        documents: [record(documentSide: side(producer: 'legacy-import'))],
        items: [placedItem(documentId: 'd1')],
      );
      final journey = build(
        project: project,
        images: picked('source.jpg', assetId: 'a1'),
      ).single;
      expect(
        byStage(journey)[JourneyStage.detection]!.outcome,
        JourneyOutcome.review,
      );
    });

    test('invalid accepted geometry is not a passed detection', () {
      final project = projectWith(
        assets: [assetNamed('a1', 'source.jpg')],
        documents: [
          record(
            documentSide: side(
              polygon: [Point2(0, 0), Point2(1, 1), Point2(1, 0), Point2(0, 1)],
            ),
          ),
        ],
        items: [placedItem(documentId: 'd1')],
      );
      final journey = build(
        project: project,
        images: picked('source.jpg', assetId: 'a1'),
      ).single;
      expect(
        byStage(journey)[JourneyStage.detection]!.outcome,
        JourneyOutcome.review,
      );
    });

    test('mixed document results never become an all-passed journey', () {
      final project = projectWith(
        assets: [assetNamed('a1', 'source.jpg')],
        documents: [
          record(id: 'd1', recognition: recognized()),
          record(
            id: 'd2',
            documentSide: side(id: 's2', cropped: false),
          ),
        ],
        items: [
          placedItem(id: 'i1', documentId: 'd1'),
          placedItem(
            id: 'i2',
            documentId: 'd2',
            pageIndex: null,
            sizeConfirmed: false,
            kind: DocumentKind.unknown,
          ),
        ],
      );
      final journey = build(
        project: project,
        images: picked('source.jpg', assetId: 'a1'),
      ).single;
      final steps = byStage(journey);
      expect(steps[JourneyStage.crop]!.outcome, JourneyOutcome.review);
      expect(steps[JourneyStage.recognition]!.outcome, JourneyOutcome.review);
      expect(steps[JourneyStage.sizing]!.outcome, JourneyOutcome.review);
      expect(steps[JourneyStage.placement]!.outcome, JourneyOutcome.review);
      expect(steps[JourneyStage.placement]!.fields['placedItems'], 1);
      expect(steps[JourneyStage.placement]!.fields['i1_placed'], isTrue);
      expect(steps[JourneyStage.placement]!.fields['i2_placed'], isFalse);
      expect(steps[JourneyStage.placement]!.fields['i2_document'], 2);
      expect(steps[JourneyStage.recognition]!.fields['d1_outcome'], 'passed');
      expect(steps[JourneyStage.recognition]!.fields['d2_outcome'], 'skipped');
      expect(steps[JourneyStage.crop]!.fields['d1_s1_warped'], isTrue);
      expect(steps[JourneyStage.crop]!.fields['d2_s1_warped'], isFalse);
      final reopened = Project.fromJson(
        jsonDecode(jsonEncode(project.toJson())),
      );
      final reopenedJourney = build(
        project: reopened,
        images: picked('source.jpg', assetId: 'a1'),
      ).single;
      expect(
        byStage(reopenedJourney)[JourneyStage.placement]!.fields,
        steps[JourneyStage.placement]!.fields,
      );
      expect(
        byStage(reopenedJourney)[JourneyStage.recognition]!.fields,
        steps[JourneyStage.recognition]!.fields,
      );
      expect(journey.placedOnSheet, isFalse);
      expect(journey.conclusion, 'أُضيف بعضها إلى الورقة وبقي بعضها للمراجعة');
      expect(journey.verdict, JourneyOutcome.review);
    });

    test('fully processed multiple documents can still pass', () {
      final project = projectWith(
        assets: [assetNamed('a1', 'source.jpg')],
        documents: [
          record(id: 'd1', recognition: recognized()),
          record(
            id: 'd2',
            documentSide: side(id: 's2'),
            recognition: recognized(kind: DocumentKind.passport),
          ),
        ],
        items: [
          placedItem(id: 'i1', documentId: 'd1'),
          placedItem(id: 'i2', documentId: 'd2', kind: DocumentKind.passport),
        ],
      );
      final journey = build(
        project: project,
        images: picked('source.jpg', assetId: 'a1'),
      ).single;
      final steps = byStage(journey);
      expect(steps[JourneyStage.crop]!.outcome, JourneyOutcome.passed);
      expect(steps[JourneyStage.recognition]!.outcome, JourneyOutcome.passed);
      expect(
        steps[JourneyStage.recognition]!.fields['d1_kind'],
        'unifiedNationalId',
      );
      expect(steps[JourneyStage.recognition]!.fields['d2_kind'], 'passport');
      expect(steps[JourneyStage.sizing]!.outcome, JourneyOutcome.passed);
      expect(steps[JourneyStage.placement]!.outcome, JourneyOutcome.passed);
    });

    test('a placed result without a saved revision is not complete', () {
      final project = projectWith(
        assets: [assetNamed('a1', 'source.jpg')],
        documents: [record(recognition: recognized())],
        items: [placedItem(documentId: 'd1')],
      );
      final journey = build(
        project: project,
        images: picked('source.jpg', assetId: 'a1'),
        revision: null,
      ).single;
      expect(
        byStage(journey)[JourneyStage.save]!.outcome,
        JourneyOutcome.skipped,
      );
      expect(journey.verdict, JourneyOutcome.review);
      expect(journey.firstConcern!.stage, JourneyStage.save);
      expect(journey.conclusion, 'لم يُحفظ المشروع بعد المعالجة');
    });

    test('a processed image reports every stage as passed', () {
      final report = projectWith(
        assets: [assetNamed('a1', 'البطاقة.jpg')],
        items: [placedItem(documentId: 'd1')],
        documents: [record(recognition: recognized())],
      );
      final journey = build(
        project: report,
        images: const [
          ImportedImageFact(
            name: 'البطاقة.jpg',
            assetId: 'a1',
            copyDurationMs: 320,
            copiedWidth: 1200,
            copiedHeight: 1600,
          ),
        ],
      ).single;
      final steps = byStage(journey);
      expect(steps.keys.toList(), JourneyStage.values);
      expect(
        steps.values.map((step) => step.outcome),
        everyElement(JourneyOutcome.passed),
      );
      expect(steps[JourneyStage.copy]!.durationMs, 320);
      expect(steps[JourneyStage.copy]!.detail, contains('1200×1600'));
      expect(steps[JourneyStage.recognition]!.detail, contains('82.0٪'));
      expect(steps[JourneyStage.sizing]!.detail, contains('85.6'));
      expect(steps[JourneyStage.placement]!.detail, contains('الصفحة 1'));
      expect(steps[JourneyStage.save]!.detail, contains('7'));
      expect(journey.conclusion, 'أُضيفت إلى الورقة');
      expect(journey.sheetRevision, 7);
    });

    test('an image with no boundary stays manual', () {
      final report = projectWith(
        assets: [assetNamed('a1', 'صورة.jpg')],
        items: [
          placedItem(
            pageIndex: null,
            sizeConfirmed: false,
            kind: DocumentKind.unknown,
          ),
        ],
      );
      final journey = build(
        project: report,
        images: picked('صورة.jpg', assetId: 'a1'),
      ).single;
      final steps = byStage(journey);
      expect(steps[JourneyStage.copy]!.outcome, JourneyOutcome.passed);
      expect(steps[JourneyStage.detection]!.outcome, JourneyOutcome.blocked);
      expect(steps[JourneyStage.crop]!.outcome, JourneyOutcome.skipped);
      expect(steps[JourneyStage.recognition]!.outcome, JourneyOutcome.skipped);
      expect(steps[JourneyStage.sizing]!.outcome, JourneyOutcome.review);
      expect(steps[JourneyStage.placement]!.outcome, JourneyOutcome.review);
      expect(journey.conclusion, 'بقيت للمراجعة اليدوية');
    });

    test('a refused copy keeps its reason and stops the path', () {
      final journey = build(
        project: projectWith(),
        images: picked('تالف.jpg', failure: 'تعذّر قراءة الملف كصورة.'),
        revision: null,
      ).single;
      final steps = byStage(journey);
      expect(steps[JourneyStage.copy]!.outcome, JourneyOutcome.blocked);
      expect(steps[JourneyStage.copy]!.detail, 'تعذّر قراءة الملف كصورة.');
      expect(steps[JourneyStage.detection]!.outcome, JourneyOutcome.skipped);
      expect(steps[JourneyStage.placement]!.outcome, JourneyOutcome.blocked);
      expect(steps[JourneyStage.save]!.outcome, JourneyOutcome.skipped);
      expect(journey.imported, isFalse);
      expect(journey.conclusion, 'لم تُستورد');
    });

    test('a weak classification is reported as review', () {
      final report = projectWith(
        assets: [assetNamed('a1', 'ورقة.jpg')],
        items: [
          placedItem(
            kind: DocumentKind.unknown,
            sizeConfirmed: false,
            pageIndex: null,
            documentId: 'd1',
          ),
        ],
        documents: [
          record(
            recognition: recognized(
              kind: DocumentKind.unknown,
              status: RecognitionStatus.uncertain,
              classification: 0.41,
            ),
          ),
        ],
      );
      final journey = build(
        project: report,
        images: picked('ورقة.jpg', assetId: 'a1'),
      ).single;
      final steps = byStage(journey);
      expect(steps[JourneyStage.detection]!.outcome, JourneyOutcome.passed);
      expect(steps[JourneyStage.crop]!.outcome, JourneyOutcome.passed);
      expect(steps[JourneyStage.recognition]!.outcome, JourneyOutcome.review);
      expect(steps[JourneyStage.recognition]!.detail, contains('تعارضت'));
      expect(
        steps[JourneyStage.recognition]!.detail,
        isNot(contains('Closure')),
      );
      expect(steps[JourneyStage.placement]!.outcome, JourneyOutcome.review);
    });

    test('a classified image reports the measured percentage', () {
      final report = projectWith(
        assets: [assetNamed('a1', 'صورة.jpg')],
        items: [placedItem(documentId: 'd1')],
        documents: [record(recognition: recognized())],
      );
      final journey = build(
        project: report,
        images: picked('صورة.jpg', assetId: 'a1'),
      ).single;
      final recognition = byStage(journey)[JourneyStage.recognition]!;
      expect(recognition.outcome, JourneyOutcome.passed);
      expect(recognition.detail, contains('90.0٪'));
      expect(recognition.detail, contains('82.0٪'));
      expect(recognition.detail, isNot(contains('Closure')));
    });

    test('an uncertain kind lists the evidence categories it saw', () {
      final report = projectWith(
        assets: [assetNamed('a1', 'صورة.jpg')],
        items: [
          placedItem(
            kind: DocumentKind.unknown,
            sizeConfirmed: false,
            pageIndex: null,
            documentId: 'd1',
          ),
        ],
        documents: [
          record(
            recognition: recognized(
              kind: DocumentKind.unknown,
              status: RecognitionStatus.uncertain,
              classification: 0.41,
              evidence: [
                RecognitionEvidence(
                  source: EvidenceSource.ocr,
                  kind: 'ocr-keyword',
                  score: 0.41,
                  reason: 'passport:anchor-groups=2:groups=title,fields',
                ),
              ],
            ),
          ),
        ],
      );
      final journey = build(
        project: report,
        images: picked('صورة.jpg', assetId: 'a1'),
      ).single;
      final recognition = byStage(journey)[JourneyStage.recognition]!;
      expect(recognition.detail, contains('العنوان المطبوع'));
      expect(recognition.detail, contains('حقول الهوية'));
      expect(recognition.detail, isNot(contains('Closure')));
    });

    test('an unread image never claims text', () {
      final report = projectWith(
        assets: [assetNamed('a1', 'صورة.jpg')],
        items: [placedItem(documentId: 'd1')],
        documents: [record(recognition: recognized(ocr: null))],
      );
      final journey = build(
        project: report,
        images: picked('صورة.jpg', assetId: 'a1'),
      ).single;
      final recognition = byStage(journey)[JourneyStage.recognition]!;
      expect(recognition.outcome, JourneyOutcome.review);
      expect(recognition.detail, contains('لم يُقرأ نص'));
    });

    test('a recorded boundary refusal states its reason', () {
      final report = projectWith(
        assets: [assetNamed('a1', 'صورة.jpg')],
        items: [placedItem(pageIndex: null, documentId: 'd1')],
        documents: [
          record(
            documentSide: side(
              diagnostics: const ['الحافة قريبة؛ راجع الزوايا.'],
              suggestion: true,
            ),
            recognition: recognized(),
          ),
        ],
      );
      final journey = build(
        project: report,
        images: picked('صورة.jpg', assetId: 'a1'),
      ).single;
      final detection = byStage(journey)[JourneyStage.detection]!;
      expect(detection.outcome, JourneyOutcome.review);
      expect(detection.detail, contains('الحافة قريبة'));
    });

    test('several recorded reasons are summarised', () {
      final report = projectWith(
        assets: [assetNamed('a1', 'صورة.jpg')],
        items: [placedItem(pageIndex: null, documentId: 'd1')],
        documents: [
          record(
            documentSide: side(
              diagnostics: const ['الحافة قريبة.', 'التحقق لم يكتمل.'],
            ),
            recognition: recognized(),
          ),
        ],
      );
      final journey = build(
        project: report,
        images: picked('صورة.jpg', assetId: 'a1'),
      ).single;
      final detail = byStage(journey)[JourneyStage.detection]!.detail;
      expect(detail, contains('الحافة قريبة.'));
      expect(detail, contains('التحقق لم يكتمل.'));
      expect(detail, isNot(contains('ملاحظة أخرى')));
      expect(detail.length, lessThanOrEqualTo(JourneyStep.maxDetailLength));
      expect(detail.contains('\n'), isFalse);
    });

    test(
      'an extracted region without corners is not reported as a perspective warp',
      () {
        final report = projectWith(
          assets: [
            assetNamed('a1', 'صورة.jpg'),
            assetNamed(
              'derived1',
              'مشتق.png',
              derivedFrom: 'a1',
              workingPath: 'projects/project1/assets/derived1/working.png',
            ),
          ],
          items: [
            placedItem(
              assetId: 'derived1',
              pageIndex: null,
              sizeConfirmed: false,
              documentId: 'd1',
            ),
          ],
          documents: [
            record(
              documentSide: side(
                cropped: false,
                processedPath: 'projects/project1/assets/derived1/working.png',
              ),
              recognition: recognized(),
            ),
          ],
        );
        final journey = build(
          project: report,
          images: picked('صورة.jpg', assetId: 'a1'),
        ).single;
        final crop = byStage(journey)[JourneyStage.crop]!;
        expect(crop.outcome, JourneyOutcome.review);
        expect(crop.detail, contains('اقتُطعت المنطقة المقاسة'));
        expect(crop.detail, contains('دون تصحيح منظور'));
        expect(crop.detail, contains('400×250 بكسل'));
      },
    );

    test('the detection step names each detector and what it measured', () {
      final report = projectWith(
        assets: [assetNamed('a1', 'صورة.jpg')],
        items: [
          placedItem(pageIndex: null, sizeConfirmed: false, documentId: 'd1'),
        ],
        documents: [
          record(
            documentSide: side(
              diagnostics: const ['لم تتوفر حدود صالحة من كاشف ثانٍ للتحقق.'],
              trace: const [
                'model=docquadnet256;outcome=proposal;confidence=0.620',
                'model=docaligner-1.1.1-fastvit-sa24;outcome=failed;'
                    'error=OnnxRuntimeException',
                'aspect=1.583',
                'area=0.410',
                'geometry=0.870',
                'catalogAspect=1.587',
                'catalogShape=mismatch',
              ],
            ),
            recognition: recognized(),
          ),
        ],
      );
      final journey = build(
        project: report,
        images: picked('صورة.jpg', assetId: 'a1'),
      ).single;
      final detail = byStage(journey)[JourneyStage.detection]!.detail;
      expect(detail, contains('DocQuadNet اقترح زوايا بدرجة 62.0٪'));
      expect(detail, contains('DocAligner تعذّر تشغيله'));
      expect(detail, contains('OnnxRuntimeException'));
      expect(detail, contains('نسبة الحدود 1.58:1'));
      expect(detail, contains('مساحة الحدود 41.0٪'));
      expect(detail, contains('جودة الهندسة 87.0٪'));
      expect(detail, contains('لم تتوفر حدود صالحة من كاشف ثانٍ'));
      final sizing = byStage(journey)[JourneyStage.sizing]!.detail;
      expect(sizing, contains('النسبة المقاسة لا تطابق الكتالوج'));
      expect(sizing, contains('1.59:1'));
      expect(detail.length, lessThanOrEqualTo(JourneyStep.maxDetailLength));
    });

    test('a manual crop repeats the measured proposal', () {
      final report = projectWith(
        assets: [assetNamed('a1', 'صورة.jpg')],
        items: [placedItem(pageIndex: null, documentId: 'd1')],
        documents: [
          record(
            documentSide: side(
              suggestion: true,
              cropped: false,
              trace: const ['aspect=1.583', 'area=0.410'],
            ),
            recognition: recognized(),
          ),
        ],
      );
      final journey = build(
        project: report,
        images: picked('صورة.jpg', assetId: 'a1'),
      ).single;
      final detail = byStage(journey)[JourneyStage.crop]!.detail;
      expect(detail, contains('الزوايا المقترحة'));
      expect(detail, contains('نسبة الحدود 1.58:1'));
      expect(detail, contains('مساحة الحدود 41.0٪'));
    });

    test('a known size that is not confirmed says which size is waiting', () {
      final report = projectWith(
        assets: [assetNamed('a1', 'صورة.jpg')],
        items: [
          placedItem(
            kind: DocumentKind.unifiedNationalId,
            sizeConfirmed: false,
            pageIndex: null,
            documentId: 'd1',
          ),
        ],
        documents: [record(recognition: recognized())],
      );
      final journey = build(
        project: report,
        images: picked('صورة.jpg', assetId: 'a1'),
      ).single;
      final detail = byStage(journey)[JourneyStage.sizing]!.detail;
      expect(detail, contains('المقاس المرجعي'));
      expect(detail, contains('85.6 × 54.0 مم'));
    });

    test('weak kind signals are named instead of denied', () {
      final report = projectWith(
        assets: [assetNamed('a1', 'صورة.jpg')],
        items: [
          placedItem(
            kind: DocumentKind.unknown,
            sizeConfirmed: false,
            pageIndex: null,
            documentId: 'd1',
          ),
        ],
        documents: [
          record(
            recognition: recognized(
              kind: DocumentKind.unknown,
              status: RecognitionStatus.unknown,
              classification: 0.41,
              evidence: [
                RecognitionEvidence(
                  source: EvidenceSource.ocr,
                  kind: 'ocr-keyword',
                  score: 0.41,
                  reason:
                      'residenceCard:anchor-groups=2:'
                      'groups=title,household',
                ),
              ],
            ),
          ),
        ],
      );
      final journey = build(
        project: report,
        images: picked('صورة.jpg', assetId: 'a1'),
      ).single;
      final detail = byStage(journey)[JourneyStage.recognition]!.detail;
      expect(detail, contains('إشارات لـ«بطاقة السكن»'));
      expect(detail, contains('دون حد القبول'));
      expect(detail, contains('حقول رب الأسرة'));
    });

    test('several images keep pick order and distinct ids', () {
      final first = assetNamed('a1', 'أول.jpg');
      final second = assetNamed('a2', 'ثانٍ.jpg');
      final items = [
        placedItem(id: 'i1', documentId: 'd1'),
        placedItem(id: 'i2', assetId: 'a2', documentId: 'd2'),
      ];
      final documents = [
        record(id: 'd1', recognition: recognized()),
        record(id: 'd2', source: 'a2', recognition: recognized()),
      ];
      final report = projectWith(
        assets: [first, second],
        items: items,
        documents: documents,
      );
      final images = [
        ...picked('أول.jpg', assetId: 'a1'),
        ...picked('ثانٍ.jpg', assetId: 'a2'),
      ];
      final journeys = build(project: report, images: images);
      expect(journeys.map((entry) => entry.imageName), ['أول.jpg', 'ثانٍ.jpg']);
      expect(journeys.map((entry) => entry.id).toSet(), hasLength(2));
    });

    test('a derived crop belongs to its source image', () {
      final report = projectWith(
        assets: [
          assetNamed('a1', 'أول.jpg'),
          ImageAsset(
            id: 'crop1',
            name: 'أول.jpg',
            originalPath: 'projects/project1/assets/crop1/original.png',
            workingPath: 'projects/project1/assets/crop1/working.png',
            thumbnailPath: 'projects/project1/assets/crop1/thumb.jpg',
            width: 600,
            height: 400,
            derivedFrom: 'a1',
          ),
        ],
        items: [
          placedItem(assetId: 'crop1', sizeConfirmed: false, documentId: 'd1'),
        ],
        documents: [record(recognition: recognized())],
      );
      final journey = build(
        project: report,
        images: picked('أول.jpg', assetId: 'a1'),
      ).single;
      final placement = byStage(journey)[JourneyStage.placement]!;
      expect(placement.outcome, JourneyOutcome.passed);
      expect(placement.detail, contains('الصفحة 1'));
    });

    test('the report never carries recognized text', () {
      final report = projectWith(
        assets: [assetNamed('a1', 'صورة.jpg')],
        items: [placedItem(documentId: 'd1')],
        documents: [record(recognition: recognized())],
      );
      final journey = build(
        project: report,
        images: picked('صورة.jpg', assetId: 'a1'),
      ).single;
      final encoded = journey.toJson().toString();
      expect(encoded.contains('الاسم'), isFalse);
      expect(encoded.contains('الرقم الوطني'), isFalse);
      expect(encoded.contains('IDIRQ'), isFalse);
    });

    test('no picked images means no reports', () {
      final report = projectWith();
      expect(build(project: report, images: const []), isEmpty);
      expect(report.revision, 7);
    });
  });
}
