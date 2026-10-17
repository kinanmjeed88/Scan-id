#ifndef RUNNER_LARGE_JPEG_SCALER_H_
#define RUNNER_LARGE_JPEG_SCALER_H_

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <thread>
#include <utility>
#include <vector>

/// Parameters passed to one bounded native JPEG operation.
struct LargeJpegScaleRequest {
  std::vector<uint8_t> bytes;
  int64_t source_width = 0;
  int64_t source_height = 0;
  int64_t orientation = 1;
  int64_t target_width = 0;
  int64_t target_height = 0;
  int64_t max_pixels = 0;

  /// True only for `cropJpegRegion`: an EXIF-oriented normalized rectangle is
  /// decoded at native density, never sampled. It shares the same bounded
  /// worker/channel as scaling so no completion can race Flutter's platform
  /// thread.
  bool full_resolution_crop = false;
  double left = 0.0;
  double top = 0.0;
  double right = 0.0;
  double bottom = 0.0;
};

/// A sampled PNG, or the platform error that should be returned to Dart.
struct LargeJpegScaleResult {
  std::vector<uint8_t> png;
  std::string error_code;
  std::string error_message;

  bool succeeded() const { return error_code.empty(); }

  static LargeJpegScaleResult Success(std::vector<uint8_t> bytes) {
    return LargeJpegScaleResult{std::move(bytes), {}, {}};
  }

  static LargeJpegScaleResult Failure(std::string code, std::string message) {
    return LargeJpegScaleResult{{}, std::move(code), std::move(message)};
  }
};

/// Injectable operation seam for deterministic native channel tests. The
/// production default is the bounded WIC sampled decoder or bounded native
/// full-resolution region decoder, selected by the request.
using LargeJpegScaleOperation =
    std::function<LargeJpegScaleResult(const LargeJpegScaleRequest&)>;

/// Posts a wake-up to the window's platform thread. It must not invoke Flutter
/// APIs itself; the channel drains and completes replies on its owner thread.
using LargeJpegPlatformWake = std::function<bool()>;

/// Windows channel for WIC sampled JPEG decode and bounded full-resolution
/// JPEG region decode. Requests outside fixed source/output budgets fail closed;
/// neither path falls back to full-frame resize or crop downsampling.
class LargeJpegScalerChannel {
 public:
  explicit LargeJpegScalerChannel(
      flutter::BinaryMessenger* messenger,
      LargeJpegPlatformWake wake_platform,
      LargeJpegScaleOperation operation = {});
  ~LargeJpegScalerChannel();

  LargeJpegScalerChannel(const LargeJpegScalerChannel&) = delete;
  LargeJpegScalerChannel& operator=(const LargeJpegScalerChannel&) = delete;

  /// Completes worker results on the thread that constructed this channel.
  /// Called by the Win32 runner when its platform-task wake message arrives.
  void DrainCompletions();

 private:
  struct State;

  std::shared_ptr<State> state_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  LargeJpegPlatformWake wake_platform_;
  std::thread::id platform_thread_;
};

#endif  // RUNNER_LARGE_JPEG_SCALER_H_
