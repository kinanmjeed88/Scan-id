#ifndef RUNNER_LARGE_JPEG_SCALER_H_
#define RUNNER_LARGE_JPEG_SCALER_H_

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <memory>

/// Windows channel for WIC's sampled JPEG decode. Requests outside the fixed
/// source/working budgets fail closed; no full-frame resize fallback exists.
class LargeJpegScalerChannel {
 public:
  explicit LargeJpegScalerChannel(flutter::BinaryMessenger* messenger);
  ~LargeJpegScalerChannel();

 private:
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

#endif  // RUNNER_LARGE_JPEG_SCALER_H_
