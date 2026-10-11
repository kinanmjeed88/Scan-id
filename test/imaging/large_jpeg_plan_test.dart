import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/domain/image_limits.dart';
import 'package:scan_id/domain/validation.dart';
import 'package:scan_id/imaging/image_header.dart';
import 'package:scan_id/imaging/large_jpeg_plan.dart';

void main() {
  test('ordinary sources stay on the existing direct decoder path', () {
    expect(withinImageBudget(4000, 4000), isTrue);
    expect(
      () =>
          LargeJpegPlan.fromHeader(ImageHeader(ImageEncoding.jpeg, 4000, 4000)),
      throwsA(isA<ValidationException>()),
    );
  });

  test('large JPEG plan is aspect-preserving and bounded to four MP', () {
    final plan = LargeJpegPlan.fromHeader(
      ImageHeader(ImageEncoding.jpeg, 5000, 4000),
    );

    expect(plan.targetPixels, lessThanOrEqualTo(maxScaledWorkingPixels));
    expect(plan.targetPixels, greaterThan(0));
    final relativeAspectError =
        ((plan.targetWidth / plan.targetHeight) /
                    (plan.sourceWidth / plan.sourceHeight) -
                1)
            .abs();
    expect(
      relativeAspectError,
      lessThanOrEqualTo(1 / plan.targetWidth + 1 / plan.targetHeight),
    );
    expect(plan.orientation, 1);
    expect(plan.transformNote, contains('5000x4000'));
  });

  test(
    'a high-aspect source too small for the analysis preview is refused',
    () {
      expect(
        () => LargeJpegPlan.fromHeader(
          ImageHeader(ImageEncoding.jpeg, 65535, 245),
        ),
        throwsA(
          isA<ValidationException>().having(
            (error) => error.message,
            'too-small-after-downscale',
            contains('أصغر'),
          ),
        ),
      );
    },
  );

  test('PNG is never eligible for the sampled JPEG plan', () {
    expect(
      () =>
          LargeJpegPlan.fromHeader(ImageHeader(ImageEncoding.png, 4000, 4000)),
      throwsA(
        isA<ValidationException>().having(
          (error) => error.message,
          'unsupported sampled decode',
          contains('PNG'),
        ),
      ),
    );
  });
}
