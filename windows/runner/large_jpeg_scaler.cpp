#include "large_jpeg_scaler.h"

#include <windows.h>
#include <wincodec.h>
#include <wrl/client.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <exception>
#include <limits>
#include <new>
#include <optional>
#include <string>
#include <variant>
#include <vector>

#pragma comment(lib, "windowscodecs.lib")
#pragma comment(lib, "ole32.lib")

namespace {
using Microsoft::WRL::ComPtr;
using flutter::EncodableMap;
using flutter::EncodableValue;

constexpr int64_t kMaxInputBytes = 20LL * 1024 * 1024;
constexpr int64_t kMaxSourcePixels = 32'000'000;
constexpr int64_t kMaxWorkingPixels = 4'000'000;
constexpr uint32_t kMaxOutputBytes = 20U * 1024U * 1024U;
constexpr UINT kMaxPreviewLongEdge = 1200;
constexpr UINT kMinPreviewShortSide = 40;

bool MeetsPreviewFloor(UINT width, UINT height) {
  if (width == 0 || height == 0) return false;
  const auto long_edge = std::max(width, height);
  const auto short_edge = std::min(width, height);
  const auto preview_short = static_cast<UINT>(std::floor(
      short_edge * std::min(1.0, static_cast<double>(kMaxPreviewLongEdge) /
                                      long_edge)));
  return preview_short >= kMinPreviewShortSide;
}

std::optional<int64_t> GetInteger(const EncodableMap& arguments,
                                  const char* key) {
  const auto found = arguments.find(EncodableValue(key));
  if (found == arguments.end()) return std::nullopt;
  if (const auto* value = std::get_if<int32_t>(&found->second)) {
    return *value;
  }
  if (const auto* value = std::get_if<int64_t>(&found->second)) {
    return *value;
  }
  return std::nullopt;
}

const std::vector<uint8_t>* GetBytes(const EncodableMap& arguments,
                                     const char* key) {
  const auto found = arguments.find(EncodableValue(key));
  if (found == arguments.end()) return nullptr;
  return std::get_if<std::vector<uint8_t>>(&found->second);
}

WICBitmapTransformOptions ExifTransform(int orientation) {
  switch (orientation) {
    case 1:
      return WICBitmapTransformRotate0;
    case 2:
      return WICBitmapTransformFlipHorizontal;
    case 3:
      return WICBitmapTransformRotate180;
    case 4:
      return WICBitmapTransformFlipVertical;
    case 5:
      // EXIF transpose: flip horizontally, then rotate 270° clockwise.
      return static_cast<WICBitmapTransformOptions>(
          WICBitmapTransformFlipHorizontal | WICBitmapTransformRotate270);
    case 6:
      return WICBitmapTransformRotate90;
    case 7:
      // EXIF transverse: flip horizontally, then rotate 90° clockwise.
      return static_cast<WICBitmapTransformOptions>(
          WICBitmapTransformFlipHorizontal | WICBitmapTransformRotate90);
    case 8:
      return WICBitmapTransformRotate270;
    default:
      return WICBitmapTransformRotate0;
  }
}

bool ScaleJpeg(const std::vector<uint8_t>& source, int64_t expected_width,
               int64_t expected_height, int64_t orientation,
               int64_t target_width, int64_t target_height,
               int64_t max_pixels, std::vector<uint8_t>* output,
               std::string* error) {
  const auto fail = [error](const char* message) {
    *error = message;
    return false;
  };
  if (source.empty() || source.size() > kMaxInputBytes || expected_width <= 0 ||
      expected_height <= 0 || expected_width > 65535 ||
      expected_height > 65535 || expected_width * expected_height >
          kMaxSourcePixels ||
      orientation < 1 || orientation > 8 || target_width <= 0 ||
      target_height <= 0 || target_width > 65535 || target_height > 65535 ||
      target_width * target_height > kMaxWorkingPixels ||
      max_pixels != target_width * target_height) {
    return fail("Image dimensions exceed the safe scaling budget.");
  }

  ComPtr<IWICImagingFactory> factory;
  HRESULT hr = CoCreateInstance(CLSID_WICImagingFactory, nullptr,
                                CLSCTX_INPROC_SERVER,
                                IID_PPV_ARGS(factory.GetAddressOf()));
  if (FAILED(hr)) return fail("WIC is unavailable.");

  ComPtr<IWICStream> input_stream;
  hr = factory->CreateStream(input_stream.GetAddressOf());
  if (FAILED(hr) || source.size() > std::numeric_limits<DWORD>::max()) {
    return fail("Could not create a bounded JPEG stream.");
  }
  hr = input_stream->InitializeFromMemory(
      const_cast<BYTE*>(reinterpret_cast<const BYTE*>(source.data())),
      static_cast<DWORD>(source.size()));
  if (FAILED(hr)) return fail("Could not read the JPEG source.");

  ComPtr<IWICBitmapDecoder> decoder;
  hr = factory->CreateDecoderFromStream(input_stream.Get(), nullptr,
                                        WICDecodeMetadataCacheOnLoad,
                                        decoder.GetAddressOf());
  if (FAILED(hr)) return fail("Unsupported or corrupt JPEG.");
  UINT frame_count = 0;
  if (FAILED(decoder->GetFrameCount(&frame_count)) || frame_count != 1) {
    return fail("Animated or multi-frame JPEG is unsupported.");
  }
  ComPtr<IWICBitmapFrameDecode> frame;
  if (FAILED(decoder->GetFrame(0, frame.GetAddressOf()))) {
    return fail("Could not read the JPEG frame.");
  }
  UINT source_width = 0, source_height = 0;
  if (FAILED(frame->GetSize(&source_width, &source_height)) ||
      source_width != static_cast<UINT>(expected_width) ||
      source_height != static_cast<UINT>(expected_height)) {
    return fail("The JPEG header does not match its decoded frame.");
  }

  // IWICBitmapSourceTransform lets the JPEG codec sample during decode. Do not
  // fall back to IWICBitmapScaler: that can materialize the full source frame.
  ComPtr<IWICBitmapSourceTransform> transform;
  if (FAILED(frame.As(&transform))) {
    return fail("This Windows JPEG codec cannot safely sample the source.");
  }
  UINT decoded_width = static_cast<UINT>(target_width);
  UINT decoded_height = static_cast<UINT>(target_height);
  bool found_bounded_size = false;
  // The in-box WIC JPEG codec samples by factors of 2, 4 or 8. A closest
  // 1/2 decode can exceed the 4 MP target for a source just above 16 MP;
  // request a smaller size and ask again rather than decoding that raster.
  for (int attempt = 0; attempt < 3; ++attempt) {
    if (FAILED(transform->GetClosestSize(&decoded_width, &decoded_height)) ||
        decoded_width == 0 || decoded_height == 0) {
      return fail("The Windows JPEG codec could not choose a sampled size.");
    }
    if (static_cast<int64_t>(decoded_width) * decoded_height <= max_pixels) {
      found_bounded_size = true;
      break;
    }
    decoded_width = std::max<UINT>(1, decoded_width / 2);
    decoded_height = std::max<UINT>(1, decoded_height / 2);
  }
  if (!found_bounded_size) {
    return fail("The Windows JPEG codec could not meet the pixel budget.");
  }
  const double expected_aspect =
      static_cast<double>(source_width) / source_height;
  const double decoded_aspect =
      static_cast<double>(decoded_width) / decoded_height;
  const double rounding_tolerance =
      1.0 / decoded_width + 1.0 / decoded_height;
  if (std::abs(decoded_aspect / expected_aspect - 1.0) >
      rounding_tolerance) {
    return fail("The Windows JPEG codec changed the source aspect ratio.");
  }

  WICPixelFormatGUID pixel_format = GUID_WICPixelFormat32bppBGRA;
  if (FAILED(transform->GetClosestPixelFormat(&pixel_format))) {
    return fail("The Windows JPEG codec returned an unsupported pixel format.");
  }
  UINT channels = 0;
  if (IsEqualGUID(pixel_format, GUID_WICPixelFormat32bppBGRA)) {
    channels = 4;
  } else if (IsEqualGUID(pixel_format, GUID_WICPixelFormat24bppBGR) ||
             IsEqualGUID(pixel_format, GUID_WICPixelFormat24bppRGB)) {
    channels = 3;
  } else if (IsEqualGUID(pixel_format, GUID_WICPixelFormat8bppGray)) {
    channels = 1;
  } else {
    return fail("The Windows JPEG codec returned an unsupported pixel format.");
  }
  const uint64_t stride64 = static_cast<uint64_t>(decoded_width) * channels;
  const uint64_t byte_count64 = stride64 * decoded_height;
  if (stride64 > std::numeric_limits<UINT>::max() ||
      byte_count64 > std::numeric_limits<UINT>::max()) {
    return fail("The sampled JPEG output exceeds the byte budget.");
  }
  const UINT stride = static_cast<UINT>(stride64);
  const UINT byte_count = static_cast<UINT>(byte_count64);
  std::vector<BYTE> pixels(byte_count);
  if (FAILED(transform->CopyPixels(
          nullptr, decoded_width, decoded_height, &pixel_format,
          WICBitmapTransformRotate0, stride, byte_count, pixels.data()))) {
    return fail("The Windows JPEG codec refused sampled decoding.");
  }

  ComPtr<IWICBitmap> bitmap;
  if (FAILED(factory->CreateBitmapFromMemory(
          decoded_width, decoded_height, pixel_format, stride, byte_count,
          pixels.data(), bitmap.GetAddressOf()))) {
    return fail("Could not construct the sampled image.");
  }
  ComPtr<IWICBitmapSource> oriented_source;
  if (orientation == 1) {
    oriented_source = bitmap;
  } else {
    ComPtr<IWICBitmapFlipRotator> rotator;
    if (FAILED(factory->CreateBitmapFlipRotator(rotator.GetAddressOf())) ||
        FAILED(rotator->Initialize(bitmap.Get(),
                                  ExifTransform(static_cast<int>(orientation))))) {
      return fail("Could not apply JPEG EXIF orientation safely.");
    }
    oriented_source = rotator;
  }
  UINT oriented_width = 0, oriented_height = 0;
  if (FAILED(oriented_source->GetSize(&oriented_width, &oriented_height)) ||
      static_cast<int64_t>(oriented_width) * oriented_height > kMaxWorkingPixels ||
      !MeetsPreviewFloor(oriented_width, oriented_height)) {
    return fail("The sampled JPEG is too small for the analysis preview.");
  }
  ComPtr<IWICFormatConverter> rgba_converter;
  if (FAILED(factory->CreateFormatConverter(rgba_converter.GetAddressOf())) ||
      FAILED(rgba_converter->Initialize(
          oriented_source.Get(), GUID_WICPixelFormat32bppBGRA,
          WICBitmapDitherTypeNone, nullptr, 0.0,
          WICBitmapPaletteTypeCustom))) {
    return fail("Could not convert the sampled JPEG to the working pixel format.");
  }
  ComPtr<IWICBitmapSource> png_source;
  if (FAILED(rgba_converter.As(&png_source))) {
    return fail("Could not prepare the sampled JPEG for PNG encoding.");
  }
  UINT output_width = 0, output_height = 0;
  if (FAILED(png_source->GetSize(&output_width, &output_height)) ||
      output_width == 0 || output_height == 0 ||
      static_cast<int64_t>(output_width) * output_height > kMaxWorkingPixels ||
      !MeetsPreviewFloor(output_width, output_height)) {
    return fail("The oriented JPEG exceeds the working pixel budget.");
  }

  std::vector<BYTE> encoded(kMaxOutputBytes);
  ComPtr<IWICStream> output_stream;
  if (FAILED(factory->CreateStream(output_stream.GetAddressOf())) ||
      FAILED(output_stream->InitializeFromMemory(encoded.data(),
                                                 kMaxOutputBytes))) {
    return fail("Could not create the bounded PNG output stream.");
  }
  ComPtr<IWICBitmapEncoder> encoder;
  if (FAILED(factory->CreateEncoder(GUID_ContainerFormatPng, nullptr,
                                    encoder.GetAddressOf())) ||
      FAILED(encoder->Initialize(output_stream.Get(), WICBitmapEncoderNoCache))) {
    return fail("Could not encode the sampled working image.");
  }
  ComPtr<IWICBitmapFrameEncode> output_frame;
  ComPtr<IPropertyBag2> properties;
  if (FAILED(encoder->CreateNewFrame(output_frame.GetAddressOf(),
                                     properties.GetAddressOf())) ||
      FAILED(output_frame->Initialize(properties.Get()))) {
    return fail("Could not create the sampled PNG frame.");
  }
  if (FAILED(output_frame->SetSize(output_width, output_height))) {
    return fail("Could not size the sampled PNG frame.");
  }
  WICPixelFormatGUID output_format = GUID_WICPixelFormat32bppBGRA;
  if (FAILED(output_frame->SetPixelFormat(&output_format)) ||
      !IsEqualGUID(output_format, GUID_WICPixelFormat32bppBGRA) ||
      FAILED(output_frame->WriteSource(png_source.Get(), nullptr)) ||
      FAILED(output_frame->Commit()) || FAILED(encoder->Commit())) {
    return fail("The sampled PNG could not be written safely.");
  }
  LARGE_INTEGER zero{};
  ULARGE_INTEGER position{};
  if (FAILED(output_stream->Seek(zero, STREAM_SEEK_CUR, &position)) ||
      position.QuadPart == 0 || position.QuadPart > kMaxOutputBytes) {
    return fail("The sampled PNG exceeds the output byte budget.");
  }
  output->assign(encoded.begin(),
                 encoded.begin() + static_cast<size_t>(position.QuadPart));
  return true;
}

}  // namespace

LargeJpegScalerChannel::LargeJpegScalerChannel(
    flutter::BinaryMessenger* messenger) {
  channel_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "iq.scanid/large_jpeg",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [](const flutter::MethodCall<EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
        if (call.method_name() != "scaleJpeg") {
          result->NotImplemented();
          return;
        }
        const auto* arguments = std::get_if<EncodableMap>(call.arguments());
        if (arguments == nullptr) {
          result->Error("invalid_request", "Missing image arguments.", nullptr);
          return;
        }
        const auto* bytes = GetBytes(*arguments, "bytes");
        const auto width = GetInteger(*arguments, "sourceWidth");
        const auto height = GetInteger(*arguments, "sourceHeight");
        const auto orientation = GetInteger(*arguments, "orientation");
        const auto target_width = GetInteger(*arguments, "targetWidth");
        const auto target_height = GetInteger(*arguments, "targetHeight");
        const auto max_pixels = GetInteger(*arguments, "maxPixels");
        if (bytes == nullptr || !width || !height || !orientation ||
            !target_width || !target_height || !max_pixels) {
          result->Error("invalid_request", "Invalid image parameters.",
                        nullptr);
          return;
        }
        try {
          std::vector<uint8_t> output;
          std::string error;
          if (!ScaleJpeg(*bytes, *width, *height, *orientation, *target_width,
                         *target_height, *max_pixels, &output, &error)) {
            result->Error("scale_failed", error, nullptr);
            return;
          }
          result->Success(EncodableValue(std::move(output)));
        } catch (const std::bad_alloc&) {
          result->Error("out_of_memory",
                        "Insufficient memory to process this JPEG safely.",
                        nullptr);
        } catch (const std::exception&) {
          result->Error("scale_failed", "The JPEG could not be scaled safely.",
                        nullptr);
        }
      });
}

LargeJpegScalerChannel::~LargeJpegScalerChannel() = default;
