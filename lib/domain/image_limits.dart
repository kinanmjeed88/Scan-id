/// Conservative phase-one limits; device profiling is still required.
const maxImportBytes = 20 * 1024 * 1024;
const maxImportPixels = 16000000;
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
