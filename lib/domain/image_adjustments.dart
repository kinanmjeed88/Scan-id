import 'validation.dart';

/// Absolute adjustments relative to the original, never cumulative re-encoding.
class ImageAdjustments {
  ImageAdjustments({
    this.brightness = 0,
    this.contrast = 1,
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
    require(quarterTurns >= 0 && quarterTurns <= 3, 'زاوية التدوير غير صالحة.');
  }
  final double brightness;
  final double contrast;
  final int quarterTurns;
  Map<String, Object?> toJson() => {
    'brightness': brightness,
    'contrast': contrast,
    'quarterTurns': quarterTurns,
  };
  factory ImageAdjustments.fromJson(Object? json) {
    final map = objectMap(json);
    return ImageAdjustments(
      brightness: finiteNumber(map['brightness'], 'brightness'),
      contrast: finiteNumber(map['contrast'], 'contrast'),
      quarterTurns: integer(map['quarterTurns'], 'quarterTurns'),
    );
  }
}
