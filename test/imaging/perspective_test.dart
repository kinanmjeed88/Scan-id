import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:scan_id/domain/crop_draft.dart';
import 'package:scan_id/domain/geometry.dart';
import 'package:scan_id/domain/image_adjustments.dart';
import 'package:scan_id/domain/validation.dart';
import 'package:scan_id/imaging/document_detector.dart';
import 'package:scan_id/imaging/perspective.dart';

Uint8List gradient(int width, int height) {
  final image = img.Image(width: width, height: height);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      image.setPixelRgb(x, y, x * 3, y * 3, 80);
    }
  }
  return img.encodePng(image);
}

void main() {
  test('full-frame identity keeps every source pixel and original bytes', () {
    final bytes = gradient(40, 30),
        before = Uint8List.fromList(gradient(40, 30));
    final image = img.decodePng(
      renderPerspective(bytes, CropDraft.fullImage().toRecipe(40, 30)),
    )!;
    final source = img.decodePng(bytes)!;
    expect([image.width, image.height], [40, 30]);
    for (var y = 0; y < 30; y++) {
      for (var x = 0; x < 40; x++) {
        expect(image.getPixel(x, y).r, source.getPixel(x, y).r);
        expect(image.getPixel(x, y).g, source.getPixel(x, y).g);
      }
    }
    expect(bytes, before);
  });
  test(
    'transparent edges use premultiplied alpha without losing hidden identity RGB',
    () {
      final source = img.Image(width: 2, height: 1, numChannels: 4);
      source.setPixelRgba(0, 0, 255, 0, 0, 255);
      source.setPixelRgba(1, 0, 0, 255, 0, 0);
      final output = warpPerspective(
        img.encodePng(source),
        ImageEditRecipe(
          CropGeometry(
            corners: CropDraft.fullImage().corners,
            outputWidth: 3,
            outputHeight: 1,
          ),
          ImageAdjustments(),
        ),
      );
      final middle = output.getPixel(1, 0), end = output.getPixel(2, 0);
      expect([middle.r, middle.g, middle.b, middle.a], [255, 0, 0, 128]);
      expect([end.r, end.g, end.b, end.a], [0, 255, 0, 0]);
    },
  );
  test('homography is projective, not bilinear interpolation of corners', () {
    final geometry = CropGeometry(
      corners: [Point2(0, 0), Point2(1, 0), Point2(.75, 1), Point2(.25, 1)],
      outputWidth: 3,
      outputHeight: 3,
    );
    final map = PerspectiveMap(geometry);
    // For this trapezoid, x=(u+.5v)/(1+v), y=2v/(1+v).
    expect(map.at(.5, .5).x, closeTo(.5, 1e-12));
    expect(map.at(.5, .5).y, closeTo(2 / 3, 1e-12));
    final image = img.decodePng(
      renderPerspective(
        gradient(80, 60),
        ImageEditRecipe(geometry, ImageAdjustments()),
      ),
    )!;
    expect(image.getPixel(1, 1).g, closeTo(118, 1));
    expect(image.getPixel(0, 0).r, 0);
    expect(image.getPixel(2, 0).r, 237);
    expect(image.getPixel(2, 2).g, 177);
  });
  test(
    'quarter-turn rotation changes dimensions without changing original',
    () {
      final draft = CropDraft.fullImage().withAdjustments(
        ImageAdjustments(quarterTurns: 1),
      );
      final image = img.decodePng(
        renderPerspective(gradient(8, 4), draft.toRecipe(8, 4)),
      )!;
      expect([image.width, image.height], [4, 8]);
      expect(image.getPixel(3, 0).r, 0);
      expect(image.getPixel(3, 0).g, 0);
      expect(image.getPixel(0, 0).g, 9);
    },
  );
  test('brightness and contrast clamp channels deterministically', () {
    final source = img.Image(width: 2, height: 2);
    img.fill(source, color: img.ColorRgb8(64, 128, 192));
    final recipe = CropDraft.fullImage()
        .withAdjustments(ImageAdjustments(brightness: .1, contrast: 2))
        .toRecipe(2, 2);
    final pixel = img
        .decodePng(renderPerspective(img.encodePng(source), recipe))!
        .getPixel(0, 0);
    expect([pixel.r, pixel.g, pixel.b, pixel.a], [26, 154, 255, 255]);
  });
  test(
    'preview keeps recipe geometry and aspect ratio at reduced raster size',
    () {
      final recipe = CropDraft.fullImage().toRecipe(80, 40);
      final preview = img.decodePng(
        renderPerspective(gradient(80, 40), recipe, previewLongEdge: 20),
      )!;
      expect([preview.width, preview.height], [20, 10]);
      expect(recipe.geometry.outputWidth, 80);
      expect(preview.getPixel(19, 9).r, 237);
      expect(preview.getPixel(19, 9).g, 117);
    },
  );
  test(
    'crossed draft remains editable but cannot become a processing request',
    () {
      final draft = CropDraft.fullImage().withCorner(1, Point2(0, 1));
      expect(
        () => draft.toRecipe(100, 100),
        throwsA(isA<ValidationException>()),
      );
    },
  );
  test('known aspect ratio is optional and does not invent physical sizes', () {
    final draft = CropDraft(
      corners: CropDraft.fullImage().corners,
      aspectRatio: .5,
    );
    final recipe = draft.toRecipe(80, 60);
    expect(
      [recipe.geometry.outputWidth, recipe.geometry.outputHeight],
      [30, 60],
    );
  });
  test('reopened saved geometry preserves exact output dimensions', () {
    final saved = CropGeometry(
      corners: CropDraft.fullImage().corners,
      outputWidth: 53,
      outputHeight: 31,
    );
    final draft = CropDraft(
      corners: saved.corners,
      aspectRatio: 53 / 31,
      preservedGeometry: saved,
    );
    final recipe = draft
        .withAdjustments(ImageAdjustments(brightness: .1))
        .toRecipe(80, 60);
    expect(recipe.geometry, same(saved));
    expect(draft.withCorner(0, Point2(.1, .1)).preservedGeometry, isNull);
  });
  test('invalid adjustment parameters are rejected before processing', () {
    expect(
      () => ImageAdjustments(brightness: double.nan),
      throwsA(isA<ValidationException>()),
    );
    expect(
      () => ImageAdjustments(contrast: 0),
      throwsA(isA<ValidationException>()),
    );
    expect(
      () => ImageAdjustments(quarterTurns: 4),
      throwsA(isA<ValidationException>()),
    );
  });
  test(
    'edge detector proposes a card on a contrasting background without applying it',
    () {
      final source = img.Image(width: 200, height: 140);
      img.fillRect(
        source,
        x1: 25,
        y1: 20,
        x2: 175,
        y2: 120,
        color: img.ColorRgb8(245, 245, 245),
      );
      final bytes = img.encodePng(source), before = img.encodePng(source);
      final points = suggestDocumentCorners(bytes);
      expect(points, isNotNull);
      expect(points![0].x, closeTo(25 / 199, .04));
      expect(points[0].y, closeTo(20 / 139, .04));
      expect(points[2].x, closeTo(175 / 199, .04));
      expect(points[2].y, closeTo(120 / 139, .04));
      expect(bytes, before);
    },
  );
  test('flat or tiny photos give no confident boundary suggestion', () {
    expect(
      suggestDocumentCorners(img.encodePng(img.Image(width: 120, height: 90))),
      isNull,
    );
    expect(
      suggestDocumentCorners(img.encodePng(img.Image(width: 2, height: 2))),
      isNull,
    );
  });
}
