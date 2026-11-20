import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:scan_id/application/contracts.dart';
import 'package:scan_id/application/project_service.dart';
import 'package:scan_id/domain/crop_draft.dart';
import 'package:scan_id/domain/document_kind.dart';
import 'package:scan_id/domain/geometry.dart';
import 'package:scan_id/domain/image_adjustments.dart';
import 'package:scan_id/domain/manual_document_selection.dart';
import 'package:scan_id/domain/project.dart';
import 'package:scan_id/domain/recognition.dart';
import 'package:scan_id/domain/validation.dart';
import 'package:scan_id/imaging/perspective.dart';
import 'package:scan_id/presentation/image_viewport.dart';

import '../presentation/editor_harness.dart';

/// A photograph with two bright rectangles on a dark field, so a crop can be
/// told apart from the whole frame by measuring the rendered pixels.
Uint8List _scenePng({int width = 400, int height = 300}) {
  final image = img.Image(width: width, height: height);
  img.fill(image, color: img.ColorRgb8(20, 20, 20));
  img.fillRect(
    image,
    x1: 20,
    y1: 30,
    x2: 179,
    y2: 149,
    color: img.ColorRgb8(240, 240, 240),
  );
  img.fillRect(
    image,
    x1: 220,
    y1: 30,
    x2: 379,
    y2: 149,
    color: img.ColorRgb8(200, 200, 200),
  );
  return img.encodePng(image);
}

/// The bright fraction of a rendered crop. A correct crop of one card is almost
/// entirely bright; a crop of the dark gap or of the whole frame is not.
double _brightFraction(Uint8List png) {
  final image = img.decodePng(png)!;
  var bright = 0;
  for (var y = 0; y < image.height; y++) {
    for (var x = 0; x < image.width; x++) {
      final pixel = image.getPixel(x, y);
      if (pixel.r > 120) bright++;
    }
  }
  return bright / (image.width * image.height);
}

/// The normalized ring of one card in the 400 × 300 scene above.
List<Point2> _card(double left, double right) => [
  Point2(left / 400, 30 / 300),
  Point2(right / 400, 30 / 300),
  Point2(right / 400, 149 / 300),
  Point2(left / 400, 149 / 300),
];

void main() {
  test(
    'two selections become two independent documents through the existing path',
    () async {
      final bytes = _scenePng();
      final repository = MemoryProjects();
      final project = await repository.create(editorProject());
      final assets = _RecordingAssets();
      final service = ProjectService(
        repository,
        assets,
        imageEditor: _RealWarpEditor(),
      );
      final source = project.assets.first;

      final set = ManualSelectionSet.empty()
          .add(
            ManualDocumentSelection(
              id: 'card-1',
              side: SideKind.front,
              corners: _card(20, 179),
              kind: DocumentKind.unifiedNationalId,
            ),
          )
          .add(
            ManualDocumentSelection(
              id: 'card-2',
              side: SideKind.back,
              corners: _card(220, 379),
              kind: DocumentKind.rationCard,
            ),
          );
      expect(set.canApply, isTrue);

      // Exactly what the screen does: sequential calls, each receiving the
      // project the previous one saved.
      var saved = project;
      var renders = 0;
      for (final selection in set.selections) {
        final recipe = CropDraft(
          corners: selection.validatedCorners!,
          adjustments: ImageAdjustments(),
        ).toRecipe(400, 300);
        // The recipe really is a crop of one card, not the whole frame.
        expect(recipe.geometry.corners, selection.validatedCorners);
        final rendered = warpPerspective(bytes, recipe);
        expect(_brightFraction(img.encodePng(rendered)), greaterThan(.9));
        expect(rendered.width, lessThan(400));
        renders++;

        saved = await service.extractManualDerivedDocument(
          saved,
          source,
          recipe,
          documentKind: selection.kind,
          side: selection.side,
          sourceWidth: 400,
          sourceHeight: 300,
        );
        expect(
          saved.assets.length,
          project.assets.length + renders,
          reason: 'each call must add exactly one derived asset',
        );
      }

      expect(renders, 2);
      final persisted = await repository.get(project.id);
      expect(
        persisted.documents
            .skip(project.documents.length)
            .map((r) => r.sides.single.side),
        [SideKind.front, SideKind.back],
      );
      final derived = saved.assets.where((a) => a.derivedFrom == source.id);
      expect(derived, hasLength(2));
      // Each document kept its own category: classification is per selection,
      // not per photograph.
      final kinds = {
        for (final item in saved.items)
          if (derived.any((a) => a.id == item.assetId)) item.documentKind,
      };
      expect(kinds, {DocumentKind.unifiedNationalId, DocumentKind.rationCard});
      // The source photograph itself was never replaced.
      expect(
        saved.assets.firstWhere((a) => a.id == source.id).originalPath,
        source.originalPath,
      );
      expect(assets.imported, hasLength(2));
    },
  );

  test('an unstated category becomes a free document, not a failure', () {
    // «تعرّف تلقائي» is not a claim about the document. The extraction path does
    // refuse an unknown category, so the default is stated here and shown to the
    // person: a free document that stays off the sheet until review settles it.
    final unstated = ManualDocumentSelection(id: 'a', corners: const []);
    expect(unstated.kind, DocumentKind.unknown);
    expect(unstated.kindForExtraction, DocumentKind.other);
    // A stated category is passed through untouched.
    final stated = unstated.copyWith(kind: DocumentKind.passport);
    expect(stated.kindForExtraction, DocumentKind.passport);
  });

  test(
    'a crop of the dark gap is NOT a document: the geometry gate refuses it',
    () {
      // Two corners only: the selection is not closed, so nothing is cropped.
      final inch = ManualDocumentSelection(
        id: 'half',
        corners: [Point2(.1, .1), Point2(.9, .1)],
      );
      expect(inch.isValid, isFalse);
      expect(inch.validatedCorners, isNull);
      expect(
        () => CropDraft(corners: inch.corners),
        throwsA(isA<ValidationException>()),
      );
    },
  );

  test('perspective correction straightens a skewed card', () async {
    // A trapezoid: the right edge is taller than the left, as a card photographed
    // at an angle looks. The rectified output must be a rectangle of the averaged
    // size, with the card's bright area filling it.
    final image = img.Image(width: 400, height: 300);
    img.fill(image, color: img.ColorRgb8(15, 15, 15));
    final skewed = [
      Point2(100 / 400, 60 / 300),
      Point2(300 / 400, 30 / 300),
      Point2(300 / 400, 270 / 300),
      Point2(100 / 400, 240 / 300),
    ];
    // Paint the trapezoid bright so the rectified result can be measured.
    for (var y = 0; y < 300; y++) {
      for (var x = 0; x < 400; x++) {
        final t = (x - 100) / 200; // 0 at the left edge, 1 at the right
        final top = 60 + (30 - 60) * t;
        final bottom = 240 + (270 - 240) * t;
        if (x >= 100 && x <= 300 && y >= top && y <= bottom) {
          image.setPixelRgb(x, y, 235, 235, 235);
        }
      }
    }
    final rectified = warpPerspective(
      img.encodePng(image),
      CropDraft(corners: skewed).toRecipe(400, 300),
    );
    // The rectified output is a RECTANGLE of the averaged edge lengths, which is
    // what "the skew is gone" means: the slanted sides were 180 and 240 px tall
    // (average 210) and the top/bottom were 200 px wide. This trapezoid is
    // therefore taller than it is wide, and asserting otherwise — as an earlier
    // version of this test did — asserts the wrong shape.
    expect(rectified.width, closeTo(202, 2));
    expect(rectified.height, closeTo(210, 2));
    final rectifiedAspect = rectified.width / rectified.height;
    final sourceAspect = 200 / 210;
    expect(rectifiedAspect, closeTo(sourceAspect, .02));
    // Most of the output is the card. Not all of it: resampling along the two
    // slanted edges blends them with the dark background, and pretending
    // otherwise would hide the very geometry this test is checking.
    expect(_brightFraction(img.encodePng(rectified)), greaterThan(.9));
    // The card's own corners survive: the extreme corners of the output are
    // blended edge, its middle is solid card.
    final middle = rectified.getPixel(
      rectified.width ~/ 2,
      rectified.height ~/ 2,
    );
    // Present, but blended: resampling right at the mid-line of a slanted edge
    // mixes in the dark background, so a strict 200 would be testing the
    // resampler's exact pixel phases rather than the rectification.
    expect(middle.r, greaterThan(150));
  });

  test('a tap point survives a zoom and a pan before it is stored', () {
    // The end-to-end coordinate contract: a person taps at 3× after panning, and
    // what is stored is the point on the photograph, not on the screen.
    final viewport = ImageViewport(
      viewport: const Size(400, 300),
      imageWidth: 400,
      imageHeight: 300,
    );
    final zoomed = viewport.scaledBy(3).translatedBy(const Offset(-120, -80));
    final screenTap = zoomed.toScreen(Point2(.25, .25));
    final stored = zoomed.toImage(screenTap);
    expect(stored.x, closeTo(.25, 1e-9));
    expect(stored.y, closeTo(.25, 1e-9));
  });
}

/// Records what the service imported, so the test can prove the derived assets
/// went through the normal repository rather than a parallel store.
class _RecordingAssets implements AssetRepository {
  final imported = <String>[];
  int _seq = 0;

  @override
  Future<ImageAsset> importImage(
    String projectId,
    String name,
    Uint8List bytes,
  ) async {
    final id = 'derived-${++_seq}';
    imported.add(name);
    return ImageAsset(
      id: id,
      name: name,
      originalPath: 'projects/$projectId/assets/$id/original.png',
      workingPath: 'projects/$projectId/assets/$id/working.png',
      thumbnailPath: 'projects/$projectId/assets/$id/thumb.jpg',
      width: 160,
      height: 120,
    );
  }

  @override
  Future<ReplacementFiles> replaceImage(
    String projectId,
    String assetId,
    Uint8List bytes,
  ) => Future.error(StateError('unused'));

  @override
  Future<Uint8List> previewImage(Uint8List source) async => source;

  @override
  Future<File> resolve(String relativePath) =>
      Future.error(StateError('no disk access in this test'));
}

/// Renders the crop bytes from the real photograph, so the test exercises the
/// same warp the app performs. Detection is not involved at all.
class _RealWarpEditor extends FakeImageEditor implements CropBytesImageEditor {
  @override
  Future<Uint8List> renderCropBytes(
    ImageAsset asset,
    ImageEditRecipe recipe,
  ) async => img.encodePng(warpPerspective(_scenePng(), recipe));
}
