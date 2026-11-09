import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:scan_id/application/cancellation.dart';
import 'package:scan_id/application/ocr_engine.dart';
import 'package:scan_id/application/project_service.dart';
import 'package:scan_id/domain/acceptance_policy.dart';
import 'package:scan_id/domain/boundary_decision.dart';
import 'package:scan_id/domain/document_kind.dart';
import 'package:scan_id/domain/geometry.dart';
import 'package:scan_id/domain/ocr_evidence.dart';
import 'package:scan_id/domain/recognition.dart';
import 'package:scan_id/imaging/boundary_proposal_cascade.dart';
import 'package:scan_id/imaging/docquad_model.dart';
import 'package:scan_id/persistence/local_asset_repository.dart';
import 'package:scan_id/persistence/local_image_editor.dart';
import 'package:scan_id/persistence/local_project_repository.dart';

class _Boundary implements BoundaryProposalModel {
  _Boundary(this.score);
  final double score;
  @override
  String get modelId => 'injected-policy-test';
  @override
  Future<BoundaryProposal?> suggestProposal(
    Uint8List bytes, {
    CancellationToken? cancellation,
  }) async => BoundaryProposal(
    producer: BoundaryProducer.learnedModel,
    corners: [Point2(.1, .1), Point2(.9, .1), Point2(.9, .9), Point2(.1, .9)],
    modelConfidence: score,
    minAutoAcceptConfidence: boundaryAcceptanceThreshold,
  );
}

class _Text implements OcrEngine {
  _Text(this.score, {this.estimated = false});
  final double? score;
  final bool estimated;
  @override
  String get version => 'injected-policy-test';
  @override
  bool get isEnabled => true;
  @override
  Future<OcrTextResult> recognize(
    Uint8List bytes, {
    CancellationToken? token,
  }) async {
    if (score == null) throw StateError('synthetic OCR failure');
    return OcrTextResult.available(
      engineVersion: version,
      lines: [
        OcrLine(
          text: estimated ? 'بطاقة السكن' : 'البطاقة الوطنية',
          confidence: score!,
        ),
        OcrLine(
          text: estimated ? 'المحلة' : 'الرقم الوطني',
          confidence: score!,
        ),
      ],
    );
  }
}

void main() {
  for (final entry in [
    (
      name: 'C60 B55 documented goes to A4',
      c: .60,
      b: .55,
      estimated: false,
      crop: true,
      placed: true,
    ),
    (
      name: 'C60 B549 preserves type for crop review',
      c: .60,
      b: .549,
      estimated: false,
      crop: false,
      placed: false,
    ),
    (
      name: 'C599 B55 preserves safe crop for manual type',
      c: .599,
      b: .55,
      estimated: false,
      crop: true,
      placed: false,
    ),
    (
      name: 'OCR failure B55 preserves crop and original',
      c: null,
      b: .55,
      estimated: false,
      crop: true,
      placed: false,
    ),
    (
      name: 'C60 B55 estimated size stays unconfirmed',
      c: .60,
      b: .55,
      estimated: true,
      crop: true,
      placed: false,
    ),
  ]) {
    test(entry.name, () async {
      final root = await Directory.systemTemp.createTemp('production-policy-');
      final projects = await LocalProjectRepository.open(root);
      addTearDown(() async {
        await projects.close();
        await root.delete(recursive: true);
      });
      final assets = LocalAssetRepository(projects.files);
      final service = ProjectService(
        projects,
        assets,
        smartRecognitionEnabled: true,
        ocr: _Text(entry.c, estimated: entry.estimated),
        imageEditor: LocalImageEditor(
          projects.files,
          boundaryProposer: BoundaryProposalCascade(
            primary: _Boundary(entry.b),
            secondary: _Boundary(entry.b),
          ),
        ),
      );
      final created = await service.create('سياسة القبول');
      // Uniform synthetic pixels avoid pretending this is model accuracy;
      // scores and OCR are injected, geometry/storage/warp/layout are real.
      final bytes = Uint8List.fromList(
        img.encodePng(img.Image(width: 400, height: 250)),
      );
      final imported = await service.importImages(created, [
        ImportSource('not-a-type.png', () => Stream.value(bytes)),
      ]);
      final original = imported.project.assets.single.originalPath;
      final result = await service.arrangeImportedImages(imported.project, [
        imported.project.assets.single.id,
      ]);
      final saved = await projects.get(result.project.id);
      expect(await (await assets.resolve(original)).readAsBytes(), bytes);
      expect(saved.assets.single.hasApprovedCrop, entry.crop);
      expect(saved.items.single.pageIndex != null, entry.placed);
      expect(saved.items.single.sizeConfirmed, entry.placed);
      final recognition = saved.documents.single.recognition!;
      expect(recognition.confidences.finalConfidence, isNull);
      if (entry.c != null && entry.c >= .60) {
        expect(recognition.status, RecognitionStatus.recognized);
        expect(
          recognition.documentKind,
          entry.estimated
              ? DocumentKind.residenceCard
              : DocumentKind.unifiedNationalId,
        );
        expect(recognition.confidences.classification!.value, .60);
      } else {
        expect(recognition.status, RecognitionStatus.unknown);
      }
    });
  }
}
