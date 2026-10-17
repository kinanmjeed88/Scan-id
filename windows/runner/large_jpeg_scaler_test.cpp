#include "large_jpeg_scaler.h"

#include <windows.h>
#include <wincodec.h>
#include <wrl/client.h>

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <future>
#include <iostream>
#include <map>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <thread>
#include <utility>
#include <variant>
#include <vector>

namespace {
using Microsoft::WRL::ComPtr;
using flutter::EncodableMap;
using flutter::EncodableValue;
using namespace std::chrono_literals;

constexpr char kChannelName[] = "iq.scanid/large_jpeg";

void Check(bool condition, const char* message) {
  if (!condition) throw std::runtime_error(message);
}

void CheckHr(HRESULT result, const char* message) {
  Check(SUCCEEDED(result), message);
}

struct RawResponse {
  std::vector<uint8_t> bytes;
};

struct DecodedResponse {
  bool success = false;
  bool not_implemented = false;
  bool value_is_bytes = false;
  std::vector<uint8_t> bytes;
  std::string error_code;
  std::string error_message;
};

class ResponseCapture final : public flutter::MethodResult<EncodableValue> {
 public:
  DecodedResponse response;

 protected:
  void SuccessInternal(const EncodableValue* result) override {
    response.success = true;
    if (result == nullptr) return;
    if (const auto* bytes = std::get_if<std::vector<uint8_t>>(result)) {
      response.value_is_bytes = true;
      response.bytes = *bytes;
    }
  }

  void ErrorInternal(const std::string& error_code,
                     const std::string& error_message,
                     const EncodableValue*) override {
    response.error_code = error_code;
    response.error_message = error_message;
  }

  void NotImplementedInternal() override {
    response.not_implemented = true;
  }
};

DecodedResponse DecodeResponse(const RawResponse& raw) {
  Check(!raw.bytes.empty(), "method response envelope was empty");
  ResponseCapture capture;
  const auto& codec = flutter::StandardMethodCodec::GetInstance();
  Check(codec.DecodeAndProcessResponseEnvelope(raw.bytes.data(),
                                               raw.bytes.size(), &capture),
        "method response envelope could not be decoded");
  return capture.response;
}

class TestPlatformPump {
 public:
  TestPlatformPump() : state_(std::make_shared<State>()) {}

  std::function<bool()> WakeCallback() const {
    const std::weak_ptr<State> weak_state = state_;
    return [weak_state] {
      const auto state = weak_state.lock();
      if (!state) return false;
      {
        std::lock_guard<std::mutex> lock(state->mutex);
        if (!state->active) return false;
        ++state->wake_count;
      }
      state->ready.notify_one();
      return true;
    };
  }

  bool WaitForWake(std::chrono::milliseconds timeout) {
    std::unique_lock<std::mutex> lock(state_->mutex);
    if (!state_->ready.wait_for(lock, timeout, [this] {
          return state_->wake_count > 0 || !state_->active;
        })) {
      return false;
    }
    if (state_->wake_count == 0) return false;
    --state_->wake_count;
    return true;
  }

  void Close() {
    {
      std::lock_guard<std::mutex> lock(state_->mutex);
      state_->active = false;
    }
    state_->ready.notify_all();
  }

 private:
  struct State {
    std::mutex mutex;
    std::condition_variable ready;
    size_t wake_count = 0;
    bool active = true;
  };

  std::shared_ptr<State> state_;
};

class TestBinaryMessenger final : public flutter::BinaryMessenger {
 public:
  struct Accounting {
    std::mutex mutex;
    bool engine_available = true;
    size_t delivered_replies = 0;
    size_t dropped_replies = 0;
    size_t duplicate_replies = 0;
  };

  TestBinaryMessenger() : accounting_(std::make_shared<Accounting>()) {}

  void Send(const std::string& channel, const uint8_t* message,
            size_t message_size, flutter::BinaryReply reply) const override {
    flutter::BinaryMessageHandler handler;
    {
      std::lock_guard<std::mutex> lock(handlers_mutex_);
      const auto found = handlers_.find(channel);
      if (found != handlers_.end()) handler = found->second;
    }
    if (!handler) {
      if (reply) reply(nullptr, 0);
      return;
    }

    const auto accounting = accounting_;
    const auto reply_count = std::make_shared<size_t>(0);
    const auto reply_count_mutex = std::make_shared<std::mutex>();
    flutter::BinaryReply tracked_reply =
        [accounting, reply_count, reply_count_mutex,
         reply = std::move(reply)](const uint8_t* response,
                                   size_t response_size) mutable {
          {
            std::lock_guard<std::mutex> count_lock(*reply_count_mutex);
            if ((*reply_count)++ != 0) {
              std::lock_guard<std::mutex> accounting_lock(accounting->mutex);
              ++accounting->duplicate_replies;
              return;
            }
          }
          {
            std::lock_guard<std::mutex> lock(accounting->mutex);
            if (!accounting->engine_available) {
              ++accounting->dropped_replies;
              return;
            }
            ++accounting->delivered_replies;
          }
          if (reply) reply(response, response_size);
        };
    handler(message, message_size, std::move(tracked_reply));
  }

  void SetMessageHandler(const std::string& channel,
                         flutter::BinaryMessageHandler handler) override {
    std::lock_guard<std::mutex> lock(handlers_mutex_);
    if (handler) {
      handlers_[channel] = std::move(handler);
    } else {
      handlers_.erase(channel);
    }
  }

  std::future<RawResponse> SendMethod(const std::string& method,
                                      EncodableValue arguments) {
    auto promise = std::make_shared<std::promise<RawResponse>>();
    auto future = promise->get_future();
    {
      std::lock_guard<std::mutex> lock(promises_mutex_);
      pending_promises_.push_back(promise);
    }
    flutter::MethodCall<EncodableValue> call(
        method, std::make_unique<EncodableValue>(std::move(arguments)));
    const auto message = flutter::StandardMethodCodec::GetInstance()
                             .EncodeMethodCall(call);
    Send(kChannelName, message->data(), message->size(),
         [promise](const uint8_t* response, size_t response_size) {
           RawResponse raw;
           if (response != nullptr && response_size > 0) {
             raw.bytes.assign(response, response + response_size);
           }
           promise->set_value(std::move(raw));
         });
    return future;
  }

  std::future<RawResponse> SendScale(const std::vector<uint8_t>& bytes,
                                     int64_t source_width = 128,
                                     int64_t source_height = 64,
                                     int64_t orientation = 1,
                                     int64_t target_width = 64,
                                     int64_t target_height = 32,
                                     int64_t max_pixels = 2048) {
    EncodableMap arguments;
    arguments.emplace(EncodableValue("bytes"), EncodableValue(bytes));
    arguments.emplace(EncodableValue("sourceWidth"),
                      EncodableValue(source_width));
    arguments.emplace(EncodableValue("sourceHeight"),
                      EncodableValue(source_height));
    arguments.emplace(EncodableValue("orientation"),
                      EncodableValue(orientation));
    arguments.emplace(EncodableValue("targetWidth"),
                      EncodableValue(target_width));
    arguments.emplace(EncodableValue("targetHeight"),
                      EncodableValue(target_height));
    arguments.emplace(EncodableValue("maxPixels"),
                      EncodableValue(max_pixels));
    return SendMethod("scaleJpeg", EncodableValue(std::move(arguments)));
  }

  std::future<RawResponse> SendCrop(
      const std::vector<uint8_t>& bytes, int64_t source_width,
      int64_t source_height, int64_t orientation, double left, double top,
      double right, double bottom,
      int64_t max_pixels = 16'000'000) {
    EncodableMap arguments;
    arguments.emplace(EncodableValue("bytes"), EncodableValue(bytes));
    arguments.emplace(EncodableValue("sourceWidth"),
                      EncodableValue(source_width));
    arguments.emplace(EncodableValue("sourceHeight"),
                      EncodableValue(source_height));
    arguments.emplace(EncodableValue("orientation"),
                      EncodableValue(orientation));
    arguments.emplace(EncodableValue("left"), EncodableValue(left));
    arguments.emplace(EncodableValue("top"), EncodableValue(top));
    arguments.emplace(EncodableValue("right"), EncodableValue(right));
    arguments.emplace(EncodableValue("bottom"), EncodableValue(bottom));
    arguments.emplace(EncodableValue("maxPixels"),
                      EncodableValue(max_pixels));
    return SendMethod("cropJpegRegion", EncodableValue(std::move(arguments)));
  }

  bool HasHandler(const std::string& channel) const {
    std::lock_guard<std::mutex> lock(handlers_mutex_);
    return handlers_.find(channel) != handlers_.end();
  }

  void StopEngine() {
    std::lock_guard<std::mutex> lock(accounting_->mutex);
    accounting_->engine_available = false;
  }

  size_t DeliveredReplies() const {
    std::lock_guard<std::mutex> lock(accounting_->mutex);
    return accounting_->delivered_replies;
  }

  size_t DroppedReplies() const {
    std::lock_guard<std::mutex> lock(accounting_->mutex);
    return accounting_->dropped_replies;
  }

  size_t DuplicateReplies() const {
    std::lock_guard<std::mutex> lock(accounting_->mutex);
    return accounting_->duplicate_replies;
  }

 private:
  mutable std::mutex handlers_mutex_;
  std::map<std::string, flutter::BinaryMessageHandler> handlers_;
  std::mutex promises_mutex_;
  std::vector<std::shared_ptr<std::promise<RawResponse>>> pending_promises_;
  std::shared_ptr<Accounting> accounting_;
};

std::vector<uint8_t> AwaitResponse(TestPlatformPump& pump,
                                   LargeJpegScalerChannel& channel,
                                   std::future<RawResponse>& future,
                                   std::chrono::milliseconds timeout = 30s) {
  const auto deadline = std::chrono::steady_clock::now() + timeout;
  while (future.wait_for(0ms) != std::future_status::ready) {
    if (std::chrono::steady_clock::now() >= deadline) {
      throw std::runtime_error("timed out waiting for a platform-thread reply");
    }
    pump.WaitForWake(5ms);
    channel.DrainCompletions();
  }
  return future.get().bytes;
}

void WaitForWorkerBarrier() {
  TestBinaryMessenger messenger;
  TestPlatformPump pump;
  LargeJpegScaleOperation operation = [](const LargeJpegScaleRequest&) {
    return LargeJpegScaleResult::Success({0x7d});
  };
  LargeJpegScalerChannel channel(&messenger, pump.WakeCallback(), operation);
  auto pending = messenger.SendScale({0x7d});
  const auto response = DecodeResponse(
      RawResponse{AwaitResponse(pump, channel, pending)});
  Check(response.success && response.value_is_bytes &&
            response.bytes == std::vector<uint8_t>({0x7d}),
        "worker barrier request failed");
}

void CheckScaleError(const RawResponse& raw, const std::string& expected_code,
                    const std::string& expected_message_fragment = {}) {
  const auto response = DecodeResponse(raw);
  Check(!response.success, "expected a method error response");
  Check(response.error_code == expected_code, "unexpected method error code");
  if (!expected_message_fragment.empty()) {
    Check(response.error_message.find(expected_message_fragment) !=
              std::string::npos,
          "method error message did not identify the failure");
  }
}

uint32_t ReadBigEndian32(const std::vector<uint8_t>& bytes, size_t offset) {
  Check(offset + 4 <= bytes.size(), "truncated PNG dimension field");
  return (static_cast<uint32_t>(bytes[offset]) << 24) |
         (static_cast<uint32_t>(bytes[offset + 1]) << 16) |
         (static_cast<uint32_t>(bytes[offset + 2]) << 8) |
         static_cast<uint32_t>(bytes[offset + 3]);
}

std::pair<uint32_t, uint32_t> ReadPngDimensions(
    const std::vector<uint8_t>& png) {
  static constexpr uint8_t kPngSignature[] = {0x89, 0x50, 0x4e, 0x47,
                                               0x0d, 0x0a, 0x1a, 0x0a};
  Check(png.size() >= 24, "sampled output is not a complete PNG header");
  for (size_t i = 0; i < sizeof(kPngSignature); ++i) {
    Check(png[i] == kPngSignature[i], "sampled output has an invalid PNG signature");
  }
  Check(png[12] == 'I' && png[13] == 'H' && png[14] == 'D' && png[15] == 'R',
        "sampled output does not begin with a PNG IHDR chunk");
  return {ReadBigEndian32(png, 16), ReadBigEndian32(png, 20)};
}

class ScopedTestComApartment {
 public:
  ScopedTestComApartment()
      : result_(CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED)) {
    CheckHr(result_, "could not initialize test COM apartment");
  }
  ~ScopedTestComApartment() {
    if (SUCCEEDED(result_)) CoUninitialize();
  }

 private:
  HRESULT result_;
};

std::vector<uint8_t> MakeSyntheticJpeg(UINT width, UINT height) {
  ScopedTestComApartment com;
  std::vector<BYTE> encoded(1024 * 1024);
  ComPtr<IWICImagingFactory> factory;
  CheckHr(CoCreateInstance(CLSID_WICImagingFactory, nullptr,
                           CLSCTX_INPROC_SERVER,
                           IID_PPV_ARGS(factory.GetAddressOf())),
          "could not create WIC factory for the synthetic JPEG");
  ComPtr<IWICStream> stream;
  CheckHr(factory->CreateStream(stream.GetAddressOf()),
          "could not create synthetic JPEG stream");
  CheckHr(stream->InitializeFromMemory(encoded.data(),
                                       static_cast<DWORD>(encoded.size())),
          "could not initialize synthetic JPEG stream");
  ComPtr<IWICBitmapEncoder> encoder;
  CheckHr(factory->CreateEncoder(GUID_ContainerFormatJpeg, nullptr,
                                 encoder.GetAddressOf()),
          "could not create synthetic JPEG encoder");
  CheckHr(encoder->Initialize(stream.Get(), WICBitmapEncoderNoCache),
          "could not initialize synthetic JPEG encoder");
  ComPtr<IWICBitmapFrameEncode> frame;
  ComPtr<IPropertyBag2> properties;
  CheckHr(encoder->CreateNewFrame(frame.GetAddressOf(),
                                  properties.GetAddressOf()),
          "could not create synthetic JPEG frame");
  CheckHr(frame->Initialize(properties.Get()),
          "could not initialize synthetic JPEG frame");
  CheckHr(frame->SetSize(width, height), "could not size synthetic JPEG frame");
  WICPixelFormatGUID format = GUID_WICPixelFormat24bppBGR;
  CheckHr(frame->SetPixelFormat(&format),
          "could not set synthetic JPEG pixel format");
  Check(IsEqualGUID(format, GUID_WICPixelFormat24bppBGR),
        "synthetic JPEG encoder selected an unexpected pixel format");

  const UINT stride = width * 3;
  std::vector<BYTE> pixels(static_cast<size_t>(stride) * height);
  for (UINT y = 0; y < height; ++y) {
    for (UINT x = 0; x < width; ++x) {
      const size_t offset = static_cast<size_t>(y) * stride + x * 3;
      pixels[offset] = static_cast<BYTE>((x + y) & 0xff);
      pixels[offset + 1] = static_cast<BYTE>((2 * x + y) & 0xff);
      pixels[offset + 2] = static_cast<BYTE>((x + 2 * y) & 0xff);
    }
  }
  CheckHr(frame->WritePixels(height, stride,
                             static_cast<UINT>(pixels.size()), pixels.data()),
          "could not write synthetic JPEG pixels");
  CheckHr(frame->Commit(), "could not commit synthetic JPEG frame");
  CheckHr(encoder->Commit(), "could not commit synthetic JPEG encoder");

  LARGE_INTEGER zero{};
  ULARGE_INTEGER position{};
  CheckHr(stream->Seek(zero, STREAM_SEEK_CUR, &position),
          "could not read synthetic JPEG length");
  Check(position.QuadPart > 0 && position.QuadPart <= encoded.size(),
        "synthetic JPEG encoder returned an invalid length");
  return std::vector<uint8_t>(
      encoded.begin(), encoded.begin() + static_cast<size_t>(position.QuadPart));
}

void TestInputValidationAndUnknownMethod() {
  TestBinaryMessenger messenger;
  TestPlatformPump pump;
  std::atomic<size_t> calls{0};
  LargeJpegScaleOperation operation =
      [&calls](const LargeJpegScaleRequest&) {
        ++calls;
        return LargeJpegScaleResult::Success({0x10});
      };
  LargeJpegScalerChannel channel(&messenger, pump.WakeCallback(), operation);

  auto missing = messenger.SendMethod("scaleJpeg", EncodableValue(EncodableMap{}));
  CheckScaleError(missing.get(), "invalid_request");
  auto unsafe_dimensions = messenger.SendScale({0x01}, 0, 64, 1, 32, 16, 512);
  CheckScaleError(unsafe_dimensions.get(), "scale_failed", "budget");
  auto unsupported = messenger.SendMethod("unknownMethod", EncodableValue());
  Check(unsupported.get().bytes.empty(),
        "unknown methods should preserve the not-implemented envelope");
  Check(calls.load() == 0,
        "invalid requests reached the asynchronous image operation");
}

void TestFullResolutionCropDispatchAndValidation() {
  TestBinaryMessenger messenger;
  TestPlatformPump pump;
  std::vector<LargeJpegScaleRequest> received;
  std::mutex received_mutex;
  LargeJpegScaleOperation operation =
      [&received, &received_mutex](const LargeJpegScaleRequest& request) {
        std::lock_guard<std::mutex> lock(received_mutex);
        received.push_back(request);
        return LargeJpegScaleResult::Success({0xc0, 0x0c});
      };
  LargeJpegScalerChannel channel(&messenger, pump.WakeCallback(), operation);

  auto invalid_budget = messenger.SendCrop({0x41}, 400, 200, 6, 0.1, 0.2,
                                           0.8, 0.9, 4'000'000);
  CheckScaleError(invalid_budget.get(), "invalid_request", "crop");
  auto pending = messenger.SendCrop({0x41, 0x42}, 400, 200, 6, 0.1, 0.2,
                                    0.8, 0.9);
  const auto response = DecodeResponse(
      RawResponse{AwaitResponse(pump, channel, pending)});
  Check(response.success && response.value_is_bytes &&
            response.bytes == std::vector<uint8_t>({0xc0, 0x0c}),
        "full-resolution crop request did not return its worker result");
  {
    std::lock_guard<std::mutex> lock(received_mutex);
    Check(received.size() == 1,
          "invalid crop request reached the asynchronous operation");
    const auto& request = received.front();
    Check(request.full_resolution_crop && request.source_width == 400 &&
              request.source_height == 200 && request.orientation == 6 &&
              request.max_pixels == 16'000'000 && request.left == 0.1 &&
              request.top == 0.2 && request.right == 0.8 &&
              request.bottom == 0.9 &&
              request.bytes == std::vector<uint8_t>({0x41, 0x42}),
          "crop request bounds or immutable source bytes changed in transit");
  }
  Check(messenger.DuplicateReplies() == 0,
        "full-resolution crop completed a method call more than once");
}

void TestWorkerThreadDispatchAndRequestAssociation() {
  TestBinaryMessenger messenger;
  TestPlatformPump pump;
  const auto platform_thread = std::this_thread::get_id();
  std::mutex worker_ids_mutex;
  std::vector<std::thread::id> worker_ids;
  std::vector<LargeJpegScaleRequest> received_requests;
  std::mutex requests_mutex;

  LargeJpegScaleOperation operation =
      [&](const LargeJpegScaleRequest& request) {
        {
          std::lock_guard<std::mutex> lock(worker_ids_mutex);
          worker_ids.push_back(std::this_thread::get_id());
        }
        {
          std::lock_guard<std::mutex> lock(requests_mutex);
          received_requests.push_back(request);
        }
        return LargeJpegScaleResult::Success(
            {request.bytes.front(),
             static_cast<uint8_t>(request.source_width & 0xff),
             static_cast<uint8_t>(request.orientation)});
      };
  LargeJpegScalerChannel channel(&messenger, pump.WakeCallback(), operation);

  const std::vector<uint8_t> first_source{0x31, 0x32};
  const std::vector<uint8_t> second_source{0x71, 0x72};
  auto first = messenger.SendScale(first_source, 321, 123, 6, 160, 80, 12800);
  auto second = messenger.SendScale(second_source, 640, 480, 3, 320, 240, 76800);

  Check(first.wait_for(0ms) == std::future_status::timeout &&
            second.wait_for(0ms) == std::future_status::timeout,
        "worker called a Flutter reply before the platform thread drained it");
  const auto first_raw = AwaitResponse(pump, channel, first);
  const auto second_raw = AwaitResponse(pump, channel, second);
  const auto first_response = DecodeResponse(RawResponse{first_raw});
  const auto second_response = DecodeResponse(RawResponse{second_raw});
  Check(first_response.success && first_response.value_is_bytes &&
            first_response.bytes == std::vector<uint8_t>({0x31, 0x41, 6}),
        "first concurrent request received another request's result");
  Check(second_response.success && second_response.value_is_bytes &&
            second_response.bytes == std::vector<uint8_t>({0x71, 0x80, 3}),
        "second concurrent request received another request's result");

  {
    std::lock_guard<std::mutex> lock(worker_ids_mutex);
    Check(worker_ids.size() == 2, "scale operation did not run once per request");
    for (const auto worker_id : worker_ids) {
      Check(worker_id != platform_thread,
            "scale operation ran on the window/platform thread");
    }
  }
  {
    std::lock_guard<std::mutex> lock(requests_mutex);
    Check(received_requests.size() == 2, "worker lost a request");
    Check(received_requests[0].source_width == 321 &&
              received_requests[0].source_height == 123 &&
              received_requests[0].orientation == 6 &&
              received_requests[0].target_width == 160 &&
              received_requests[0].target_height == 80 &&
              received_requests[0].max_pixels == 12800 &&
              received_requests[0].bytes == first_source,
          "first request's source geometry or immutable bytes changed");
    Check(received_requests[1].source_width == 640 &&
              received_requests[1].source_height == 480 &&
              received_requests[1].orientation == 3 &&
              received_requests[1].bytes == second_source,
          "second request's source geometry or immutable bytes changed");
  }
  Check(first_source == std::vector<uint8_t>({0x31, 0x32}) &&
            second_source == std::vector<uint8_t>({0x71, 0x72}),
        "native scaling modified a caller-owned source buffer");
  Check(messenger.DuplicateReplies() == 0,
        "a method request was completed more than once");
}

void TestWicSuccessDimensionsOrientationAndSourcePreservation() {
  TestBinaryMessenger messenger;
  TestPlatformPump pump;
  LargeJpegScalerChannel channel(&messenger, pump.WakeCallback());

  const auto jpeg = MakeSyntheticJpeg(512, 256);
  const auto original = jpeg;
  auto pending = messenger.SendScale(jpeg, 512, 256, 6, 256, 128, 32768);
  const auto raw = AwaitResponse(pump, channel, pending);
  const auto response = DecodeResponse(RawResponse{raw});
  Check(response.success && response.value_is_bytes,
        "WIC did not return a sampled PNG");

  const auto dimensions = ReadPngDimensions(response.bytes);
  Check(dimensions.first == 128 && dimensions.second == 256,
        "WIC output did not preserve sampled size and EXIF rotation");
  Check(static_cast<uint64_t>(dimensions.first) * dimensions.second <= 32768,
        "WIC output exceeded the working pixel limit");
  Check(jpeg == original,
        "WIC decode or sampled conversion modified the input JPEG bytes");
  Check(messenger.DuplicateReplies() == 0,
        "WIC success completed a method call more than once");
}

void TestWicFullResolutionCropDimensionsOrientationAndSourcePreservation() {
  TestBinaryMessenger messenger;
  TestPlatformPump pump;
  LargeJpegScalerChannel channel(&messenger, pump.WakeCallback());

  const auto jpeg = MakeSyntheticJpeg(512, 256);
  const auto original = jpeg;
  // Orientation six has an oriented 256 by 512 canvas. This request is its
  // central half, which must remain full density (128 by 256) after rotation.
  auto pending = messenger.SendCrop(jpeg, 512, 256, 6, 0.25, 0.25, 0.75, 0.75);
  const auto response = DecodeResponse(
      RawResponse{AwaitResponse(pump, channel, pending)});
  if (!response.success || !response.value_is_bytes) {
    throw std::runtime_error(
        "WIC did not return a full-resolution cropped PNG: " +
        response.error_code + " " + response.error_message);
  }
  const auto dimensions = ReadPngDimensions(response.bytes);
  Check(dimensions.first == 128 && dimensions.second == 256,
        "WIC crop did not preserve the selected EXIF-oriented dimensions");
  Check(static_cast<uint64_t>(dimensions.first) * dimensions.second == 32768,
        "WIC crop unexpectedly sampled the requested full-resolution region");
  Check(jpeg == original,
        "WIC crop modified the input JPEG bytes");
  Check(messenger.DuplicateReplies() == 0,
        "WIC crop completed a method call more than once");
}

void TestDecodeConversionAndEncodeFailuresReturnErrors() {
  TestBinaryMessenger messenger;
  TestPlatformPump pump;
  LargeJpegScaleOperation operation =
      [](const LargeJpegScaleRequest& request) {
        if (request.bytes.front() == 0x22) {
          return LargeJpegScaleResult::Failure(
              "scale_failed", "Could not convert the sampled JPEG.");
        }
        if (request.bytes.front() == 0x33) {
          return LargeJpegScaleResult::Failure(
              "scale_failed", "The sampled PNG could not be written safely.");
        }
        return LargeJpegScaleResult::Success({request.bytes.front()});
      };
  LargeJpegScalerChannel channel(&messenger, pump.WakeCallback(), operation);

  auto conversion = messenger.SendScale({0x22});
  auto encoding = messenger.SendScale({0x33});
  CheckScaleError(RawResponse{AwaitResponse(pump, channel, conversion)},
                  "scale_failed", "convert");
  CheckScaleError(RawResponse{AwaitResponse(pump, channel, encoding)},
                  "scale_failed", "written");
  auto recovered = messenger.SendScale({0x44});
  const auto success = DecodeResponse(
      RawResponse{AwaitResponse(pump, channel, recovered)});
  Check(success.success && success.value_is_bytes &&
            success.bytes == std::vector<uint8_t>({0x44}),
        "worker failed to recover after conversion/encoding errors");

  // Exercise a real WIC decode rejection as well as the deterministic later
  // stage failures above.
  TestBinaryMessenger wic_messenger;
  TestPlatformPump wic_pump;
  LargeJpegScalerChannel wic_channel(&wic_messenger, wic_pump.WakeCallback());
  auto corrupt = wic_messenger.SendScale({0xff, 0x00, 0x13, 0x37}, 64, 32, 1,
                                         32, 16, 512);
  CheckScaleError(
      RawResponse{AwaitResponse(wic_pump, wic_channel, corrupt)},
      "scale_failed", "JPEG");
}

void TestConcurrencyLimitRejectsExcessWork() {
  TestBinaryMessenger messenger;
  TestPlatformPump pump;
  struct Gate {
    std::mutex mutex;
    std::condition_variable condition;
    bool release = false;
  };
  auto gate = std::make_shared<Gate>();
  auto started = std::make_shared<std::promise<void>>();
  auto started_future = started->get_future();
  LargeJpegScaleOperation operation =
      [gate, started](const LargeJpegScaleRequest& request) {
        if (request.bytes.front() == 1) {
          started->set_value();
          std::unique_lock<std::mutex> lock(gate->mutex);
          gate->condition.wait(lock, [&] { return gate->release; });
        }
        return LargeJpegScaleResult::Success({request.bytes.front()});
      };
  LargeJpegScalerChannel channel(&messenger, pump.WakeCallback(), operation);

  auto first = messenger.SendScale({1});
  Check(started_future.wait_for(5s) == std::future_status::ready,
        "first bounded worker request did not start");
  auto second = messenger.SendScale({2});
  auto third = messenger.SendScale({3});
  Check(third.wait_for(0ms) == std::future_status::ready,
        "over-capacity request was queued instead of rejected");
  CheckScaleError(third.get(), "busy", "busy");

  {
    std::lock_guard<std::mutex> lock(gate->mutex);
    gate->release = true;
  }
  gate->condition.notify_all();
  const auto first_response = DecodeResponse(
      RawResponse{AwaitResponse(pump, channel, first)});
  const auto second_response = DecodeResponse(
      RawResponse{AwaitResponse(pump, channel, second)});
  Check(first_response.success && first_response.bytes ==
                                       std::vector<uint8_t>({1}),
        "first bounded request lost its result");
  Check(second_response.success && second_response.bytes ==
                                        std::vector<uint8_t>({2}),
        "second bounded request lost its result");
}

void TestPluginShutdownCancelsInFlightAndDropsLateResult() {
  TestBinaryMessenger messenger;
  TestPlatformPump pump;
  struct Gate {
    std::mutex mutex;
    std::condition_variable condition;
    bool release = false;
  };
  auto gate = std::make_shared<Gate>();
  auto started = std::make_shared<std::promise<void>>();
  auto finished = std::make_shared<std::promise<void>>();
  auto started_future = started->get_future();
  auto finished_future = finished->get_future();
  LargeJpegScaleOperation operation =
      [gate, started, finished](const LargeJpegScaleRequest&) {
        started->set_value();
        {
          std::unique_lock<std::mutex> lock(gate->mutex);
          gate->condition.wait(lock, [&] { return gate->release; });
        }
        finished->set_value();
        return LargeJpegScaleResult::Success({0x5a});
      };
  auto channel = std::make_unique<LargeJpegScalerChannel>(
      &messenger, pump.WakeCallback(), operation);
  auto pending = messenger.SendScale({0x5a});
  Check(started_future.wait_for(5s) == std::future_status::ready,
        "in-flight shutdown request did not start");

  channel.reset();
  Check(!messenger.HasHandler(kChannelName),
        "channel destruction left its messenger handler registered");
  CheckScaleError(pending.get(), "cancelled", "shutting down");
  {
    std::lock_guard<std::mutex> lock(gate->mutex);
    gate->release = true;
  }
  gate->condition.notify_all();
  Check(finished_future.wait_for(5s) == std::future_status::ready,
        "in-flight WIC-equivalent operation did not leave its worker");
  WaitForWorkerBarrier();
  Check(messenger.DeliveredReplies() == 1 &&
            messenger.DuplicateReplies() == 0,
        "late worker completion replied after channel teardown");
}

void TestEngineShutdownDropsCallbacksWithoutRetainingWindow() {
  TestBinaryMessenger messenger;
  TestPlatformPump pump;
  struct Gate {
    std::mutex mutex;
    std::condition_variable condition;
    bool release = false;
  };
  auto gate = std::make_shared<Gate>();
  auto started = std::make_shared<std::promise<void>>();
  auto finished = std::make_shared<std::promise<void>>();
  auto started_future = started->get_future();
  auto finished_future = finished->get_future();
  LargeJpegScaleOperation operation =
      [gate, started, finished](const LargeJpegScaleRequest&) {
        started->set_value();
        {
          std::unique_lock<std::mutex> lock(gate->mutex);
          gate->condition.wait(lock, [&] { return gate->release; });
        }
        finished->set_value();
        return LargeJpegScaleResult::Success({0x66});
      };
  auto channel = std::make_unique<LargeJpegScalerChannel>(
      &messenger, pump.WakeCallback(), operation);
  auto pending = messenger.SendScale({0x66});
  Check(started_future.wait_for(5s) == std::future_status::ready,
        "engine-shutdown request did not start");

  messenger.StopEngine();
  channel.reset();
  Check(!messenger.HasHandler(kChannelName),
        "engine shutdown left the method handler registered");
  Check(messenger.DroppedReplies() == 1,
        "shutdown cancellation was not discarded by the stopped messenger");
  {
    std::lock_guard<std::mutex> lock(gate->mutex);
    gate->release = true;
  }
  gate->condition.notify_all();
  Check(finished_future.wait_for(5s) == std::future_status::ready,
        "worker did not finish after engine shutdown");
  WaitForWorkerBarrier();
  Check(pending.wait_for(0ms) == std::future_status::timeout,
        "a dead engine unexpectedly received a late response");
  Check(messenger.DroppedReplies() == 1 &&
            messenger.DuplicateReplies() == 0,
        "worker touched the stopped engine after teardown");
}

}  // namespace

int main() {
  try {
    TestInputValidationAndUnknownMethod();
    TestFullResolutionCropDispatchAndValidation();
    TestWorkerThreadDispatchAndRequestAssociation();
    TestWicSuccessDimensionsOrientationAndSourcePreservation();
    TestWicFullResolutionCropDimensionsOrientationAndSourcePreservation();
    TestDecodeConversionAndEncodeFailuresReturnErrors();
    TestConcurrencyLimitRejectsExcessWork();
    TestPluginShutdownCancelsInFlightAndDropsLateResult();
    TestEngineShutdownDropsCallbacksWithoutRetainingWindow();
  } catch (const std::exception& exception) {
    std::cerr << "large_jpeg_scaler_test failed: " << exception.what() << '\n';
    return 1;
  }
  std::cout << "large_jpeg_scaler_test passed\n";
  return 0;
}
