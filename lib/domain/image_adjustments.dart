import 'validation.dart';

/// Absolute adjustments relative to the original, never cumulative re-encoding.
class ImageAdjustments {
  ImageAdjustments({
    this.brightness = 0,
    this.contrast = 1,
    this.saturation = 1,
    this.sharpness = 0,
    this.quarterTurns = 0,
  }) {
    require(
      brightness.isFinite && brightness >= -.5 && brightness <= .5,
      'الإضاءة خارج المجال المسموح.',
    );
    require(
      contrast.isFinite && contrast >= .25 && contrast <= 3,
      'التباين خارج المجال المسموح.',
    );
    require(
      saturation.isFinite && saturation >= 0 && saturation <= 2,
      'تشبع اللون خارج المجال المسموح.',
    );
    require(
      sharpness.isFinite && sharpness >= 0 && sharpness <= 1,
      'حدة الصورة خارج المجال المسموح.',
    );
    require(quarterTurns >= 0 && quarterTurns <= 3, 'زاوية التدوير غير صالحة.');
  }

  final double brightness;
  final double contrast;
  final double saturation;
  final double sharpness;
  final int quarterTurns;

  bool get hasColorChange =>
      brightness != 0 || contrast != 1 || saturation != 1;

  /// Same values with neutral colour (geometry and sharpness kept).
  ImageAdjustments get colorNeutral =>
      ImageAdjustments(sharpness: sharpness, quarterTurns: quarterTurns);

  /// 4×5 row-major colour matrix (offsets in 0–255 units) that reproduces the
  /// export pipeline's saturation → contrast → brightness step exactly:
  /// `out = ((L + (c − L)·s) − ½)·k + ½ + b`, with Rec. 709 luminance L.
  /// The preview applies it on the GPU, so colour edits are visible while a
  /// slider is still moving.
  List<double> get colorMatrix {
    const lr = .2126, lg = .7152, lb = .0722;
    final s = saturation, k = contrast;
    final offset = 255 * (.5 - .5 * k + brightness);
    List<double> row(double r, double g, double b) => [
      k * r,
      k * g,
      k * b,
      0,
      offset,
    ];
    return [
      ...row(lr * (1 - s) + s, lg * (1 - s), lb * (1 - s)),
      ...row(lr * (1 - s), lg * (1 - s) + s, lb * (1 - s)),
      ...row(lr * (1 - s), lg * (1 - s), lb * (1 - s) + s),
      0,
      0,
      0,
      1,
      0,
    ];
  }

  ImageAdjustments copyWith({
    double? brightness,
    double? contrast,
    double? saturation,
    double? sharpness,
    int? quarterTurns,
  }) => ImageAdjustments(
    brightness: brightness ?? this.brightness,
    contrast: contrast ?? this.contrast,
    saturation: saturation ?? this.saturation,
    sharpness: sharpness ?? this.sharpness,
    quarterTurns: quarterTurns ?? this.quarterTurns,
  );

  Map<String, Object?> toJson() => {
    'brightness': brightness,
    'contrast': contrast,
    'saturation': saturation,
    'sharpness': sharpness,
    'quarterTurns': quarterTurns,
  };

  factory ImageAdjustments.fromJson(Object? json) {
    final map = objectMap(json);
    return ImageAdjustments(
      brightness: map['brightness'] == null
          ? 0
          : finiteNumber(map['brightness'], 'brightness'),
      contrast: map['contrast'] == null
          ? 1
          : finiteNumber(map['contrast'], 'contrast'),
      saturation: map['saturation'] == null
          ? 1
          : finiteNumber(map['saturation'], 'saturation'),
      sharpness: map['sharpness'] == null
          ? 0
          : finiteNumber(map['sharpness'], 'sharpness'),
      quarterTurns: map['quarterTurns'] == null
          ? 0
          : integer(map['quarterTurns'], 'quarterTurns'),
    );
  }
}
