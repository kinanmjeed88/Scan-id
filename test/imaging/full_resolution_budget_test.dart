import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/domain/crop_draft.dart';
import 'package:scan_id/domain/geometry.dart';
import 'package:scan_id/domain/image_limits.dart';
import 'package:scan_id/domain/validation.dart';
import 'package:scan_id/imaging/full_resolution_manual_crop.dart';

// D7: one shared 16 MP predicate for the sampled recipe path (CropDraft
// .toRecipe) and the full-density path (requireFullResolutionCropFits).
// Synthetic dimensions only; no image data is decoded here.

const _fullFrame = (left: 0.0, top: 0.0, right: 1.0, bottom: 1.0);

const _sizes = [1, 2, 3999, 4000, 4001, 16000000, 16000001];

bool _fullFrameRefused(int width, int height) {
  try {
    requireFullResolutionCropFits(
      bounds: _fullFrame,
      orientedWidth: width,
      orientedHeight: height,
    );
    return false;
  } on ValidationException {
    return true;
  }
}

bool _recipeRefused(int width, int height) {
  try {
    CropDraft.fullImage().toRecipe(width, height);
    return false;
  } on ValidationException {
    return true;
  }
}

void main() {
  test('withinImageBudget: exact boundary and hostile dimensions', () {
    expect(withinImageBudget(4000, 4000), isTrue);
    expect(withinImageBudget(4000, 4001), isFalse);
    expect(withinImageBudget(1, maxImportPixels), isTrue);
    expect(withinImageBudget(maxImportPixels, 1), isTrue);
    expect(withinImageBudget(maxImportPixels + 1, 1), isFalse);
    expect(withinImageBudget(0, 5), isFalse);
    expect(withinImageBudget(-1, 5), isFalse);
    // A 64-bit product of these wraps to 0; the per-side check refuses first.
    expect(withinImageBudget(4294967296, 4294967296), isFalse);
    expect(withinImageBudget(3037000500, 3037000500), isFalse);
  });

  test('full-density path accepts exactly the budget and refuses above it', () {
    expect(_fullFrameRefused(4000, 4000), isFalse);
    expect(_fullFrameRefused(4001, 4000), isTrue);
    expect(_fullFrameRefused(1, maxImportPixels), isFalse);
    expect(_fullFrameRefused(maxImportPixels + 1, 1), isTrue);
  });

  test('both paths agree with the shared predicate over a size grid', () {
    for (final w in _sizes) {
      for (final h in _sizes) {
        final budget = withinImageBudget(w, h);
        final refused = _fullFrameRefused(w, h);
        expect(refused, !budget, reason: 'full-density path, ${w}x$h');
        expect(_recipeRefused(w, h), !budget, reason: 'recipe path, ${w}x$h');
      }
    }
  });

  test('snappedSpanPixels refuses intervals outside the image', () {
    final refused = throwsA(isA<ValidationException>());
    expect(() => snappedSpanPixels(-0.1, 0.5, 100), refused);
    expect(() => snappedSpanPixels(0.5, 1.1, 100), refused);
    expect(() => snappedSpanPixels(double.nan, 0.5, 100), refused);
    expect(() => snappedSpanPixels(0.6, 0.6, 100), refused);
    // Valid interval keeps the existing floor/ceil snap.
    expect(snappedSpanPixels(0.25, 0.75, 100), 50);
    expect(snappedSpanPixels(0, 1, 16000001), 16000001);
  });

  test('sampled recipe never exceeds the budget for in-budget sources', () {
    final rotated = [
      Point2(.5, 0),
      Point2(1, .5),
      Point2(.5, 1),
      Point2(0, .5),
    ];
    final corners = [
      CropDraft.fullImage(),
      CropDraft(corners: rotated),
      CropDraft(corners: rotated, aspectRatio: 1.5),
    ];
    for (final w in [1, 2, 100, 3999, 4000]) {
      for (final h in [1, 2, 100, 3999, 4000]) {
        if (!withinImageBudget(w, h)) continue;
        for (final draft in corners) {
          final geometry = draft.toRecipe(w, h).geometry;
          final outW = geometry.outputWidth;
          final outH = geometry.outputHeight;
          final fits = withinImageBudget(outW, outH);
          expect(fits, isTrue, reason: 'source ${w}x$h');
        }
      }
    }
  });

  test('toRecipe keeps a crop at exactly the budget unscaled', () {
    // Estimated output equals the budget: scale is 1, so no pixel is dropped.
    final full4000 = CropDraft.fullImage().toRecipe(4000, 4000).geometry;
    expect(full4000.outputWidth, 4000);
    expect(full4000.outputHeight, 4000);
    final wide = CropDraft.fullImage().toRecipe(6000, 2000).geometry;
    expect(wide.outputWidth, 6000);
    expect(wide.outputHeight, 2000);
  });

  test('toRecipe silently scales an over-budget estimate to the budget', () {
    // Source 8000x2000 is in budget (16,000,000 px). The skewed quad's
    // estimate is about 4352.58 x 4800.40 (about 20.9 MP). Scale is
    // sqrt(16e6 / 20.89e6) = 0.875080; floored output is 3808 x 4200.
    // The fractional parts (0.857 and 0.735) keep floor() clear of any
    // float-error flip.
    final skewed = CropDraft(
      corners: [Point2(0, 1), Point2(.8, 0), Point2(1, 0), Point2(1, 1)],
    );
    final geometry = skewed.toRecipe(8000, 2000).geometry;
    expect(geometry.outputWidth, 3808);
    expect(geometry.outputHeight, 4200);
    expect(
      withinImageBudget(geometry.outputWidth, geometry.outputHeight),
      isTrue,
    );
    expect(geometry.outputWidth * geometry.outputHeight, 15993600);
  });

  test('toRecipe refuses a hostile 64-bit source before any product', () {
    // Each side exceeds the budget, so the per-side check refuses first and
    // the product (which wraps in 64-bit) is never trusted.
    expect(_recipeRefused(4294967296, 4294967296), isTrue);
    expect(_recipeRefused(maxImportPixels + 1, 1), isTrue);
  });

  test('CropGeometry itself refuses an output above the budget', () {
    final corners = [Point2(0, 0), Point2(1, 0), Point2(1, 1), Point2(0, 1)];
    void build() {
      CropGeometry(corners: corners, outputWidth: 4001, outputHeight: 4000);
    }

    expect(build, throwsA(isA<ValidationException>()));
  });
}
