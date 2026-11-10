import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/application/image_journey_report.dart';
import 'package:scan_id/domain/document_kind.dart';
import 'package:scan_id/domain/image_journey.dart';
import 'package:scan_id/domain/project.dart';
import 'package:scan_id/domain/recognition.dart';

/// An asset with a readable name, so a report can be about a real image.
ImageAsset assetNamed(String id, String name) => ImageAsset(
  id: id,
  name: name,
  originalPath: 'projects/project1/assets/$id/original.png',
  workingPath: 'projects/project1/assets/$id/working.png',
  thumbnailPath: 'projects/project1/assets/$id/thumb.jpg',
  width: 1200,
  height: 1600,
);

DocumentSide side({
  String id = 'side1',
  bool processed = true,
  double? confidence = 0.82,
  List<String> diagnostics = const [],
  bool suggestion = false,
}) => DocumentSide(
  id: id,
  side: SideKind.unknown,
  processedAsset: ProcessedAssetRef(
    workingPath: processed
        ? 'projects/project1/processed/$id.png'
        : 'projects/project1/assets/asset1/working.png',
    thumbnailPath: 'projects/project1/processed/$id-thumb.jpg',
    width: 400,
    height: 250,
    outputWidth: processed ? 1011 : null,
    outputHeight: processed ? 638 : null,
  ),
  detection: DetectionRef(
    detectionId: 'det-$id',
    producer: 'docquad',
    version: 'v1',
    detectionConfidence: confidence == null
        ? null
        : Confidence(value: confidence),
    boundaryDiagnostics: diagnostics,
    suggestedPolygon: suggestion
        ? [Point2(0.1, 0.1), Point2(0.9, 0.1), Point2(0.9, 0.9), Point2(0.1, 0.9)]
        : null,
  ),
);

DocumentRecord record({
  String id = 'doc1',
  String sourceImageId = 'asset1',
  DocumentSide? documentSide,
  RecognitionResult? recognition,
}) => DocumentRecord(
  id: id,
  sourceImageId: sourceImageId,
  sides: [documentSide ?? side()],
  pairing: PairingState.single,
  recognition: recognition,
  provenance: Provenance(
    sourceImageId: sourceImageId,
    detectionIds: ['det-side1'],
    processedAssetVersion: 'smart-1',
    pipelineVersion: 'smart-1',
  ),
);

RecognitionResult recognized({
  DocumentKind kind = DocumentKind.unifiedNationalId,
  RecognitionStatus status = RecognitionStatus.recognized,
  double? ocr = 0.9,
  double? classification = 0.82,
}) => RecognitionResult(
  documentKind: kind,
  status: status,
  confidences: ConfidenceSet(
    ocr: ocr == null ? null : Confidence(value: ocr),
    classification: classification == null
        ? null
        : Confidence(value: classification),
  ),
  preset: const PresetSelection.resolved('unified-national-id'),
);

DocumentItem placedItem({
  String id = 'item1',
  String assetId = 'asset1',
  int? pageIndex = 0,
  bool sizeConfirmed = true,
  DocumentKind kind = DocumentKind.unifiedNationalId,
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
);

Project projectWith({
  List<ImageAsset> assets = const [],
  List<DocumentItem> items = const [],
  List<DocumentRecord> documents = const [],
  int revision = 7,
}) => Project(
  id: 'project1',
  name: 'مستمسكات العائلة',
  createdAt: DateTime.utc(2026, 10, 6),
  updatedAt: DateTime.utc(2026, 10, 6),
  revision: revision,
  assets: assets,
  items: items,
  documents: documents,
);

Map<JourneyStage, JourneyStep> byStage(ImageJourney journey) => {
  for (final step in journey.steps) step.stage: step,
};

void main() {
  group('journey report', () {
    test('a fully processed image reports every stage as passed', () {
      final report = projectWith(
        assets: [assetNamed('asset1', 'البطاقة الوطنية.jpg')],
        items: [placedItem()],
        documents: [record(recognition: recognized())],
      );
      final journeys = buildImageJourneys(
        batchId: 'batch-0001',
        project: report,
        images: const [
          ImportedImageFact(
            name: 'البطاقة الوطنية.jpg',
            assetId: 'asset1',
            copyDurationMs: 320,
          ),
        ],
        startedAt: DateTime.utc(2026, 11, 9, 9),
        savedRevision: 7,
      );

      expect(journeys, hasLength(1));
      final journey = journeys.single;
      final steps = byStage(journey);
      expect(steps.keys.toList(), JourneyStage.values);
      expect(
        steps.values.map((step) => step.outcome),
        everyElement(JourneyOutcome.passed),
      );
      expect(steps[JourneyStage.copy]!.durationMs, 320);
      expect(steps[JourneyStage.copy]!.detail, contains('1200×1600'));
      expect(
        steps[JourneyStage.recognition]!.detail,
        allOf(contains('البطاقة الوطنية الموحدة'), contains('82.0٪')),
      );
      expect(steps[JourneyStage.sizing]!.detail, contains('85.6'));
      expect(steps[JourneyStage.placement]!.detail, contains('الصفحة 1'));
      expect(steps[JourneyStage.save]!.detail, contains('7'));
      expect(journey.conclusion, 'أُضيفت إلى الورقة');
      expect(journey.sheetRevision, 7);
    });

    test('an image with no usable boundary is reported as manual, and the '
        'later stages say they never ran', () {
      final report = projectWith(
        assets: [assetNamed('asset1', 'صورة.jpg')],
        items: [
          placedItem(
            pageIndex: null,
            sizeConfirmed: false,
            kind: DocumentKind.unknown,
          ),
        ],
      );
      final journey = buildImageJourneys(
        batchId: 'batch-0002',
        project: report,
        images: const [
          ImportedImageFact(name: 'صورة.jpg', assetId: 'asset1'),
        ],
        startedAt: DateTime.utc(2026, 11, 9, 9),
        savedRevision: 8,
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

    test('a refused copy is reported with its reason and nothing after it '
        'pretends to have run', () {
      final report = projectWith();
      final journey = buildImageJourneys(
        batchId: 'batch-0003',
        project: report,
        images: const [
          ImportedImageFact(
            name: 'تالف.jpg',
            failureMessage: 'تعذّر قراءة الملف كصورة.',
          ),
        ],
        startedAt: DateTime.utc(2026, 11, 9, 9),
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

    test('a weak classification is reported as review, not as a decision', () {
      final report = projectWith(
        assets: [assetNamed('asset1', 'ورقة.jpg')],
        items: [
          placedItem(
            kind: DocumentKind.unknown,
            sizeConfirmed: false,
            pageIndex: null,
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
      final journey = buildImageJourneys(
        batchId: 'batch-0004',
        project: report,
        images: const [
          ImportedImageFact(name: 'ورقة.jpg', assetId: 'asset1'),
        ],
        startedAt: DateTime.utc(2026, 11, 9, 9),
        savedRevision: 9,
      ).single;
      final steps = byStage(journey);
      expect(steps[JourneyStage.detection]!.outcome, JourneyOutcome.passed);
      expect(steps[JourneyStage.crop]!.outcome, JourneyOutcome.passed);
      expect(steps[JourneyStage.recognition]!.outcome, JourneyOutcome.review);
      expect(
        steps[JourneyStage.recognition]!.detail,
        contains('تعارضت'),
      );
      expect(steps[JourneyStage.placement]!.outcome, JourneyOutcome.review);
    });

    test('an image whose OCR could not run says so instead of claiming text',
        () {
      final report = projectWith(
        assets: [assetNamed('asset1', 'صورة.jpg')],
        items: [placedItem()],
        documents: [
          record(recognition: recognized(ocr: null, classification: null)),
        ],
      );
      final journey = buildImageJourneys(
        batchId: 'batch-0005',
        project: report,
        images: const [
          ImportedImageFact(name: 'صورة.jpg', assetId: 'asset1'),
        ],
        startedAt: DateTime.utc(2026, 11, 9, 9),
        savedRevision: 10,
      ).single;
      final recognition = byStage(journey)[JourneyStage.recognition]!;
      expect(recognition.outcome, JourneyOutcome.review);
      expect(recognition.detail, contains('لم يُقرأ نص'));
    });

    test('a recorded boundary refusal states the reason that decided it', () {
      final report = projectWith(
        assets: [assetNamed('asset1', 'صورة.jpg')],
        items: [placedItem(pageIndex: null)],
        documents: [
          record(
            documentSide: side(
              diagnostics: ['الحافة قريبة من إطار الصورة؛ راجع الزوايا.'],
              suggestion: true,
            ),
            recognition: recognized(),
          ),
        ],
      );
      final journey = buildImageJourneys(
        batchId: 'batch-0006',
        project: report,
        images: const [
          ImportedImageFact(name: 'صورة.jpg', assetId: 'asset1'),
        ],
        startedAt: DateTime.utc(2026, 11, 9, 9),
        savedRevision: 11,
      ).single;
      final detection = byStage(journey)[JourneyStage.detection]!;
      expect(detection.outcome, JourneyOutcome.review);
      expect(detection.detail, contains('إطار الصورة'));
    });

    test('a long recorded reason is clipped to one bounded sentence', () {
      final long = 'سبب طويل جداً ' * 40;
      final report = projectWith(
        assets: [assetNamed('asset1', 'صورة.jpg')],
        items: [placedItem(pageIndex: null)],
        documents: [
          record(
            documentSide: side(diagnostics: [long]),
            recognition: recognized(),
          ),
        ],
      );
      final journey = buildImageJourneys(
        batchId: 'batch-0007',
        project: report,
        images: const [
          ImportedImageFact(name: 'صورة.jpg', assetId: 'asset1'),
        ],
        startedAt: DateTime.utc(2026, 11, 9, 9),
        savedRevision: 12,
      ).single;
      final detail = byStage(journey)[JourneyStage.detection]!.detail;
      expect(detail.length, lessThanOrEqualTo(JourneyStep.maxDetailLength));
      expect(detail.endsWith('…'), isTrue);
      expect(detail.contains('\n'), isFalse);
    });

    test('several images keep pick order and get distinct ids', () {
      final report = projectWith(
        assets: [
          assetNamed('asset1', 'أول.jpg'),
          assetNamed('asset2', 'ثانٍ.jpg'),
        ],
        items: [
          placedItem(id: 'item1', assetId: 'asset1'),
          placedItem(id: 'item2', assetId: 'asset2'),
        ],
        documents: [
          record(id: 'doc1', sourceImageId: 'asset1', recognition: recognized()),
          record(id: 'doc2', sourceImageId: 'asset2', recognition: recognized()),
        ],
      );
      final journeys = buildImageJourneys(
        batchId: 'batch-0008',
        project: report,
        images: const [
          ImportedImageFact(name: 'أول.jpg', assetId: 'asset1'),
          ImportedImageFact(name: 'ثانٍ.jpg', assetId: 'asset2'),
        ],
        startedAt: DateTime.utc(2026, 11, 9, 9),
        savedRevision: 13,
      );
      expect(journeys.map((entry) => entry.imageName), ['أول.jpg', 'ثانٍ.jpg']);
      expect(journeys.map((entry) => entry.id).toSet(), hasLength(2));
      expect(journeys.map((entry) => entry.batchId).toSet(), {'batch-0008'});
    });

    test('a derived crop is reported as part of its source image', () {
      final derived = ImageAsset(
        id: 'asset1-crop',
        name: 'أول.jpg',
        originalPath: 'projects/project1/assets/asset1-crop/original.png',
        workingPath: 'projects/project1/assets/asset1-crop/working.png',
        thumbnailPath: 'projects/project1/assets/asset1-crop/thumb.jpg',
        width: 600,
        height: 400,
        derivedFrom: 'asset1',
      );
      final report = projectWith(
        assets: [assetNamed('asset1', 'أول.jpg'), derived],
        items: [placedItem(assetId: 'asset1-crop', sizeConfirmed: false)],
        documents: [record(recognition: recognized())],
      );
      final journey = buildImageJourneys(
        batchId: 'batch-0009',
        project: report,
        images: const [
          ImportedImageFact(name: 'أول.jpg', assetId: 'asset1'),
        ],
        startedAt: DateTime.utc(2026, 11, 9, 9),
        savedRevision: 14,
      ).single;
      final steps = byStage(journey);
      expect(steps[JourneyStage.placement]!.outcome, JourneyOutcome.passed);
      expect(steps[JourneyStage.placement]!.detail, contains('الصفحة 1'));
    });

    test('the report never carries recognized text or personal values', () {
      final report = projectWith(
        assets: [assetNamed('asset1', 'صورة.jpg')],
        items: [placedItem()],
        documents: [record(recognition: recognized())],
      );
      final journey = buildImageJourneys(
        batchId: 'batch-0010',
        project: report,
        images: const [
          ImportedImageFact(name: 'صورة.jpg', assetId: 'asset1'),
        ],
        startedAt: DateTime.utc(2026, 11, 9, 9),
        savedRevision: 15,
      ).single;
      final encoded = journey.toJson().toString();
      expect(encoded.contains('الاسم'), isFalse);
      expect(encoded.contains('الرقم الوطني'), isFalse);
      expect(encoded.contains('IDIRQ'), isFalse);
    });

    test('no images means no reports, and the project is untouched', () {
      final report = projectWith();
      expect(
        buildImageJourneys(
          batchId: 'batch-0011',
          project: report,
          images: const [],
          startedAt: DateTime.utc(2026, 11, 9, 9),
        ),
        isEmpty,
      );
      expect(report.revision, 7);
    });
  });
}
