/// Conservative phase-one limits; device profiling is still required.
const maxImportBytes = 20 * 1024 * 1024;
const maxImportPixels = 16000000;

/// Large JPEGs are reduced with a platform decoder that supports sampled
/// decoding. The source-size cap bounds native decoder work independently of
/// the four-megapixel working copy.
const maxScalableJpegSourcePixels = 32000000;
const maxScaledWorkingPixels = 4000000;
const maxScaledWorkingBytes = maxImportBytes;

/// Recognition works on a copy capped at this long edge. The segmenter refuses
/// any preview whose short edge is below its existing minimum.
const maxRecognitionPreviewLongEdge = 1200;
const minRecognitionPreviewSide = 40;
const maxProjectAssets = 200;
const maxProjectItems = 500;

/// Check each side before multiplying: Dart VM integers are signed 64-bit and
/// hostile 32-bit PNG dimensions can wrap their product into a small value.
bool withinImageBudget(int width, int height) =>
    width > 0 &&
    height > 0 &&
    width <= maxImportPixels &&
    height <= maxImportPixels &&
    width * height <= maxImportPixels;
