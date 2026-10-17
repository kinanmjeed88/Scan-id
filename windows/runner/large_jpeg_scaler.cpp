#include "large_jpeg_scaler.h"

#include <windows.h>
#include <wincodec.h>
#include <wrl/client.h>

#include <algorithm>
#include <array>
#include <cmath>
#include <condition_variable>
#include <cstdint>
#include <deque>
#include <exception>
#include <functional>
#include <limits>
#include <mutex>
#include <new>
#include <optional>
#include <stdexcept>
#include <string>
#include <thread>
#include <utility>
#include <variant>
#include <vector>

#pragma comment(lib, "windowscodecs.lib")
#pragma comment(lib, "ole32.lib")

namespace {
using Microsoft::WRL::ComPtr;
using flutter::EncodableMap;
using flutter::EncodableValue;
using MethodResult = flutter::MethodResult<EncodableValue>;

constexpr int64_t kMaxInputBytes = 20LL * 1024 * 1024;
constexpr int64_t kMaxSourcePixels = 32'000'000;
constexpr int64_t kMaxWorkingPixels = 4'000'000;
constexpr int64_t kMaxFullResolutionCropPixels = 16'000'000;
constexpr uint32_t kMaxOutputBytes = 20U * 1024U * 1024U;
constexpr UINT kMaxPreviewLongEdge = 1200;
constexpr UINT kMinPreviewShortSide = 40;
constexpr size_t kMaxOutstandingRequests = 2;

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

std::optional<double> GetNumber(const EncodableMap& arguments,
                                const char* key) {
  const auto found = arguments.find(EncodableValue(key));
  if (found == arguments.end()) return std::nullopt;
  if (const auto* value = std::get_if<double>(&found->second)) return *value;
  if (const auto* value = std::get_if<int32_t>(&found->second)) {
    return static_cast<double>(*value);
  }
  if (const auto* value = std::get_if<int64_t>(&found->second)) {
    return static_cast<double>(*value);
  }
  return std::nullopt;
}

const std::vector<uint8_t>* GetBytes(const EncodableMap& arguments,
                                     const char* key) {
  const auto found = arguments.find(EncodableValue(key));
  if (found == arguments.end()) return nullptr;
  return std::get_if<std::vector<uint8_t>>(&found->second);
}

bool HasSafeScaleBudgets(uint64_t source_bytes, int64_t source_width,
                         int64_t source_height, int64_t orientation,
                         int64_t target_width, int64_t target_height,
                         int64_t max_pixels) {
  return source_bytes > 0 &&
         source_bytes <= static_cast<uint64_t>(kMaxInputBytes) &&
         source_width > 0 && source_height > 0 && source_width <= 65535 &&
         source_height <= 65535 &&
         source_width * source_height <= kMaxSourcePixels && orientation >= 1 &&
         orientation <= 8 && target_width > 0 && target_height > 0 &&
         target_width <= 65535 && target_height <= 65535 &&
         target_width * target_height <= kMaxWorkingPixels &&
         max_pixels == target_width * target_height;
}

bool HasSafeCropBudgets(uint64_t source_bytes, int64_t source_width,
                        int64_t source_height, int64_t orientation,
                        double left, double top, double right, double bottom,
                        int64_t max_pixels) {
  return source_bytes > 0 &&
         source_bytes <= static_cast<uint64_t>(kMaxInputBytes) &&
         source_width > 0 && source_height > 0 && source_width <= 65535 &&
         source_height <= 65535 &&
         source_width * source_height <= kMaxSourcePixels && orientation >= 1 &&
         orientation <= 8 && std::isfinite(left) && std::isfinite(top) &&
         std::isfinite(right) && std::isfinite(bottom) && left >= 0.0 &&
         top >= 0.0 && right <= 1.0 && bottom <= 1.0 && left < right &&
         top < bottom && max_pixels == kMaxFullResolutionCropPixels;
}

std::pair<double, double> RawPointFromOriented(
    double x, double y, UINT width, UINT height, int orientation) {
  switch (orientation) {
    case 1:
      return {x, y};
    case 2:
      return {static_cast<double>(width) - x, y};
    case 3:
      return {static_cast<double>(width) - x,
              static_cast<double>(height) - y};
    case 4:
      return {x, static_cast<double>(height) - y};
    case 5:
      return {y, x};
    case 6:
      return {y, static_cast<double>(height) - x};
    case 7:
      return {static_cast<double>(width) - y,
              static_cast<double>(height) - x};
    case 8:
      return {static_cast<double>(width) - y, x};
    default:
      return {x, y};
  }
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

bool ScaleJpegWic(const LargeJpegScaleRequest& request,
                  std::vector<uint8_t>* output, std::string* error) {
  const auto fail = [error](const char* message) {
    *error = message;
    return false;
  };
  if (!HasSafeScaleBudgets(
          request.bytes.size(), request.source_width, request.source_height,
          request.orientation, request.target_width, request.target_height,
          request.max_pixels)) {
    return fail("Image dimensions exceed the safe scaling budget.");
  }

  ComPtr<IWICImagingFactory> factory;
  HRESULT hr = CoCreateInstance(CLSID_WICImagingFactory, nullptr,
                               CLSCTX_INPROC_SERVER,
                               IID_PPV_ARGS(factory.GetAddressOf()));
  if (FAILED(hr)) return fail("WIC is unavailable.");

  ComPtr<IWICStream> input_stream;
  hr = factory->CreateStream(input_stream.GetAddressOf());
  if (FAILED(hr) || request.bytes.size() > std::numeric_limits<DWORD>::max()) {
    return fail("Could not create a bounded JPEG stream.");
  }
  hr = input_stream->InitializeFromMemory(
      const_cast<BYTE*>(reinterpret_cast<const BYTE*>(request.bytes.data())),
      static_cast<DWORD>(request.bytes.size()));
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
      source_width != static_cast<UINT>(request.source_width) ||
      source_height != static_cast<UINT>(request.source_height)) {
    return fail("The JPEG header does not match its decoded frame.");
  }

  // IWICBitmapSourceTransform lets the JPEG codec sample during decode. Do not
  // fall back to IWICBitmapScaler: that can materialize the full source frame.
  ComPtr<IWICBitmapSourceTransform> transform;
  if (FAILED(frame.As(&transform))) {
    return fail("This Windows JPEG codec cannot safely sample the source.");
  }
  UINT decoded_width = static_cast<UINT>(request.target_width);
  UINT decoded_height = static_cast<UINT>(request.target_height);
  bool found_bounded_size = false;
  // The in-box WIC JPEG codec samples by factors of 2, 4 or 8. A closest
  // 1/2 decode can exceed the 4 MP target for a source just above 16 MP;
  // request a smaller size and ask again rather than decoding that raster.
  for (int attempt = 0; attempt < 3; ++attempt) {
    if (FAILED(transform->GetClosestSize(&decoded_width, &decoded_height)) ||
        decoded_width == 0 || decoded_height == 0) {
      return fail("The Windows JPEG codec could not choose a sampled size.");
    }
    if (static_cast<int64_t>(decoded_width) * decoded_height <=
        request.max_pixels) {
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
  if (request.orientation == 1) {
    oriented_source = bitmap;
  } else {
    ComPtr<IWICBitmapFlipRotator> rotator;
    if (FAILED(factory->CreateBitmapFlipRotator(rotator.GetAddressOf())) ||
        FAILED(rotator->Initialize(
            bitmap.Get(), ExifTransform(static_cast<int>(request.orientation))))) {
      return fail("Could not apply JPEG EXIF orientation safely.");
    }
    oriented_source = rotator;
  }
  UINT oriented_width = 0, oriented_height = 0;
  if (FAILED(oriented_source->GetSize(&oriented_width, &oriented_height)) ||
      static_cast<int64_t>(oriented_width) * oriented_height >
          kMaxWorkingPixels ||
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
bool CropJpegRegionWic(const LargeJpegScaleRequest& request,
                       std::vector<uint8_t>* output, std::string* error) {
  const auto fail = [error](const char* message) {
    *error = message;
    return false;
  };
  if (!HasSafeCropBudgets(
          request.bytes.size(), request.source_width, request.source_height,
          request.orientation, request.left, request.top, request.right,
          request.bottom, request.max_pixels)) {
    return fail("Full-resolution JPEG crop parameters exceed the safe budget.");
  }

  ComPtr<IWICImagingFactory> factory;
  HRESULT hr = CoCreateInstance(CLSID_WICImagingFactory, nullptr,
                               CLSCTX_INPROC_SERVER,
                               IID_PPV_ARGS(factory.GetAddressOf()));
  if (FAILED(hr)) return fail("WIC is unavailable.");
  ComPtr<IWICStream> input_stream;
  if (FAILED(factory->CreateStream(input_stream.GetAddressOf())) ||
      request.bytes.size() > std::numeric_limits<DWORD>::max() ||
      FAILED(input_stream->InitializeFromMemory(
          const_cast<BYTE*>(reinterpret_cast<const BYTE*>(request.bytes.data())),
          static_cast<DWORD>(request.bytes.size())))) {
    return fail("Could not read the bounded JPEG source.");
  }
  ComPtr<IWICBitmapDecoder> decoder;
  if (FAILED(factory->CreateDecoderFromStream(input_stream.Get(), nullptr,
                                               WICDecodeMetadataCacheOnLoad,
                                               decoder.GetAddressOf()))) {
    return fail("Unsupported or corrupt JPEG.");
  }
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
      source_width != static_cast<UINT>(request.source_width) ||
      source_height != static_cast<UINT>(request.source_height)) {
    return fail("The JPEG header does not match its decoded frame.");
  }

  const bool swaps_axes = request.orientation >= 5 && request.orientation <= 8;
  const UINT oriented_width = swaps_axes ? source_height : source_width;
  const UINT oriented_height = swaps_axes ? source_width : source_height;
  const double ox0 = std::floor(request.left * oriented_width);
  const double oy0 = std::floor(request.top * oriented_height);
  const double ox1 = std::ceil(request.right * oriented_width);
  const double oy1 = std::ceil(request.bottom * oriented_height);
  if (!(ox0 >= 0.0 && oy0 >= 0.0 && ox1 <= oriented_width &&
        oy1 <= oriented_height && ox0 < ox1 && oy0 < oy1)) {
    return fail("The normalized JPEG crop is empty or out of bounds.");
  }
  const std::array<std::pair<double, double>, 4> corners = {
      RawPointFromOriented(ox0, oy0, source_width, source_height,
                            static_cast<int>(request.orientation)),
      RawPointFromOriented(ox1, oy0, source_width, source_height,
                            static_cast<int>(request.orientation)),
      RawPointFromOriented(ox1, oy1, source_width, source_height,
                            static_cast<int>(request.orientation)),
      RawPointFromOriented(ox0, oy1, source_width, source_height,
                            static_cast<int>(request.orientation)),
  };
  double min_x = corners.front().first, max_x = min_x;
  double min_y = corners.front().second, max_y = min_y;
  for (const auto& corner : corners) {
    min_x = std::min(min_x, corner.first);
    max_x = std::max(max_x, corner.first);
    min_y = std::min(min_y, corner.second);
    max_y = std::max(max_y, corner.second);
  }
  const int64_t raw_left = std::clamp<int64_t>(
      static_cast<int64_t>(std::floor(min_x)), 0, source_width);
  const int64_t raw_top = std::clamp<int64_t>(
      static_cast<int64_t>(std::floor(min_y)), 0, source_height);
  const int64_t raw_right = std::clamp<int64_t>(
      static_cast<int64_t>(std::ceil(max_x)), 0, source_width);
  const int64_t raw_bottom = std::clamp<int64_t>(
      static_cast<int64_t>(std::ceil(max_y)), 0, source_height);
  const int64_t crop_width = raw_right - raw_left;
  const int64_t crop_height = raw_bottom - raw_top;
  if (crop_width <= 0 || crop_height <= 0) {
    return fail("The JPEG crop is empty.");
  }
  if (crop_width * crop_height > request.max_pixels) {
    return fail("The full-resolution JPEG crop exceeds the 16 MP pixel budget.");
  }

  // The JPEG codec receives a raw source rectangle and the requested output
  // is that exact size: no sampled decode or resize is permitted in this path.
  ComPtr<IWICBitmapSourceTransform> transform;
  if (FAILED(frame.As(&transform))) {
    return fail("This Windows JPEG codec cannot crop the source safely.");
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
  const uint64_t stride64 = static_cast<uint64_t>(crop_width) * channels;
  const uint64_t byte_count64 = stride64 * crop_height;
  if (stride64 > std::numeric_limits<UINT>::max() ||
      byte_count64 > std::numeric_limits<UINT>::max()) {
    return fail("The full-resolution JPEG crop exceeds the byte budget.");
  }
  const UINT stride = static_cast<UINT>(stride64);
  const UINT byte_count = static_cast<UINT>(byte_count64);
  std::vector<BYTE> pixels(byte_count);
  WICRect crop_rect{static_cast<INT>(raw_left), static_cast<INT>(raw_top),
                    static_cast<INT>(crop_width), static_cast<INT>(crop_height)};
  if (FAILED(transform->CopyPixels(
          &crop_rect, static_cast<UINT>(crop_width),
          static_cast<UINT>(crop_height), &pixel_format,
          WICBitmapTransformRotate0, stride, byte_count, pixels.data()))) {
    return fail("The Windows JPEG codec refused full-resolution region decoding.");
  }
  ComPtr<IWICBitmap> bitmap;
  if (FAILED(factory->CreateBitmapFromMemory(
          static_cast<UINT>(crop_width), static_cast<UINT>(crop_height),
          pixel_format, stride, byte_count, pixels.data(),
          bitmap.GetAddressOf()))) {
    return fail("Could not construct the full-resolution crop.");
  }
  ComPtr<IWICBitmapSource> oriented_source;
  if (request.orientation == 1) {
    oriented_source = bitmap;
  } else {
    ComPtr<IWICBitmapFlipRotator> rotator;
    if (FAILED(factory->CreateBitmapFlipRotator(rotator.GetAddressOf())) ||
        FAILED(rotator->Initialize(
            bitmap.Get(), ExifTransform(static_cast<int>(request.orientation))))) {
      return fail("Could not apply JPEG EXIF orientation to the crop.");
    }
    oriented_source = rotator;
  }
  ComPtr<IWICFormatConverter> rgba_converter;
  if (FAILED(factory->CreateFormatConverter(rgba_converter.GetAddressOf())) ||
      FAILED(rgba_converter->Initialize(
          oriented_source.Get(), GUID_WICPixelFormat32bppBGRA,
          WICBitmapDitherTypeNone, nullptr, 0.0,
          WICBitmapPaletteTypeCustom))) {
    return fail("Could not convert the full-resolution crop for PNG encoding.");
  }
  ComPtr<IWICBitmapSource> png_source;
  if (FAILED(rgba_converter.As(&png_source))) {
    return fail("Could not prepare the full-resolution crop for PNG encoding.");
  }
  UINT output_width = 0, output_height = 0;
  if (FAILED(png_source->GetSize(&output_width, &output_height)) ||
      output_width == 0 || output_height == 0 ||
      static_cast<int64_t>(output_width) * output_height > request.max_pixels) {
    return fail("The full-resolution crop exceeds the pixel budget after orientation.");
  }
  std::vector<BYTE> encoded(kMaxOutputBytes);
  ComPtr<IWICStream> output_stream;
  if (FAILED(factory->CreateStream(output_stream.GetAddressOf())) ||
      FAILED(output_stream->InitializeFromMemory(encoded.data(),
                                                 kMaxOutputBytes))) {
    return fail("Could not create the bounded PNG crop output stream.");
  }
  ComPtr<IWICBitmapEncoder> encoder;
  if (FAILED(factory->CreateEncoder(GUID_ContainerFormatPng, nullptr,
                                    encoder.GetAddressOf())) ||
      FAILED(encoder->Initialize(output_stream.Get(), WICBitmapEncoderNoCache))) {
    return fail("Could not encode the full-resolution crop.");
  }
  ComPtr<IWICBitmapFrameEncode> output_frame;
  ComPtr<IPropertyBag2> properties;
  if (FAILED(encoder->CreateNewFrame(output_frame.GetAddressOf(),
                                     properties.GetAddressOf())) ||
      FAILED(output_frame->Initialize(properties.Get())) ||
      FAILED(output_frame->SetSize(output_width, output_height))) {
    return fail("Could not create the full-resolution PNG frame.");
  }
  WICPixelFormatGUID output_format = GUID_WICPixelFormat32bppBGRA;
  if (FAILED(output_frame->SetPixelFormat(&output_format)) ||
      !IsEqualGUID(output_format, GUID_WICPixelFormat32bppBGRA) ||
      FAILED(output_frame->WriteSource(png_source.Get(), nullptr)) ||
      FAILED(output_frame->Commit()) || FAILED(encoder->Commit())) {
    return fail("The full-resolution PNG crop could not be written safely.");
  }
  LARGE_INTEGER zero{};
  ULARGE_INTEGER position{};
  if (FAILED(output_stream->Seek(zero, STREAM_SEEK_CUR, &position)) ||
      position.QuadPart == 0 || position.QuadPart > kMaxOutputBytes) {
    return fail("The full-resolution PNG crop exceeds the output byte budget.");
  }
  output->assign(encoded.begin(),
                 encoded.begin() + static_cast<size_t>(position.QuadPart));
  return true;
}

class ScopedComApartment {
 public:
  ScopedComApartment() : result_(CoInitializeEx(nullptr, COINIT_MULTITHREADED)) {}
  ~ScopedComApartment() {
    if (SUCCEEDED(result_)) CoUninitialize();
  }

  HRESULT result() const { return result_; }

 private:
  HRESULT result_;
};

LargeJpegScaleResult ScaleJpegOnWorker(
    const LargeJpegScaleRequest& request) {
  // WIC objects are created, used, and released within this worker job's MTA.
  // No COM interface crosses the apartment or worker boundary.
  ScopedComApartment apartment;
  if (FAILED(apartment.result())) {
    return LargeJpegScaleResult::Failure(
        "scale_failed", "Could not initialize COM for safe JPEG processing.");
  }
  try {
    std::vector<uint8_t> output;
    std::string error;
    const bool completed = request.full_resolution_crop
        ? CropJpegRegionWic(request, &output, &error)
        : ScaleJpegWic(request, &output, &error);
    if (!completed) {
      const char* code = request.full_resolution_crop &&
                  error.find("budget") != std::string::npos
          ? "crop_too_large"
          : "scale_failed";
      return LargeJpegScaleResult::Failure(code, std::move(error));
    }
    return LargeJpegScaleResult::Success(std::move(output));
  } catch (const std::bad_alloc&) {
    return LargeJpegScaleResult::Failure(
        "out_of_memory", "Insufficient memory to process this JPEG safely.");
  } catch (const std::exception&) {
    return LargeJpegScaleResult::Failure(
        "scale_failed", "The JPEG could not be scaled safely.");
  } catch (...) {
    return LargeJpegScaleResult::Failure(
        "scale_failed", "The JPEG could not be scaled safely.");
  }
}

class SerialScaleWorker {
 public:
  using Task = std::function<void()>;

  SerialScaleWorker() : worker_([this] { Run(); }) {}

  ~SerialScaleWorker() {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      stopping_ = true;
      pending_ -= tasks_.size();
      tasks_.clear();
    }
    ready_.notify_one();
    if (worker_.joinable()) worker_.join();
  }

  bool TrySubmit(Task task) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (stopping_ || pending_ >= kMaxOutstandingRequests) return false;
    tasks_.push_back(std::move(task));
    ++pending_;
    ready_.notify_one();
    return true;
  }

 private:
  void Run() {
    for (;;) {
      Task task;
      {
        std::unique_lock<std::mutex> lock(mutex_);
        ready_.wait(lock, [this] { return stopping_ || !tasks_.empty(); });
        if (stopping_ && tasks_.empty()) return;
        task = std::move(tasks_.front());
        tasks_.pop_front();
      }

      try {
        task();
      } catch (...) {
        // The submitted closure converts operation failures to a platform
        // result. This boundary also keeps an unexpected exception from
        // terminating the process-wide worker thread.
      }

      {
        std::lock_guard<std::mutex> lock(mutex_);
        --pending_;
      }
    }
  }

  std::mutex mutex_;
  std::condition_variable ready_;
  std::deque<Task> tasks_;
  size_t pending_ = 0;
  bool stopping_ = false;
  std::thread worker_;
};

SerialScaleWorker& GetSerialScaleWorker() {
  static SerialScaleWorker worker;
  return worker;
}

void ReplyWithError(std::unique_ptr<MethodResult> result,
                    const char* code, const char* message) {
  if (!result) return;
  try {
    result->Error(code, message, EncodableValue(nullptr));
  } catch (...) {
    // A failure to encode a response must not escape a runner callback.
  }
}

}  // namespace

struct LargeJpegScalerChannel::State {
  enum class RegistrationStatus { kAccepted, kClosed, kBusy };

  struct Registration {
    RegistrationStatus status;
    uint64_t request_id = 0;
  };

  struct PendingRequest {
    uint64_t request_id = 0;
    std::unique_ptr<MethodResult> result;
    std::optional<LargeJpegScaleResult> completion;
  };

  Registration Register(std::unique_ptr<MethodResult>& result) {
    std::lock_guard<std::mutex> lock(mutex);
    if (!active) return {RegistrationStatus::kClosed, 0};

    PendingRequest* slot = nullptr;
    for (auto& candidate : pending) {
      if (!candidate.result) {
        slot = &candidate;
        break;
      }
    }
    if (slot == nullptr) return {RegistrationStatus::kBusy, 0};

    uint64_t request_id = next_request_id++;
    for (;;) {
      bool id_in_use = false;
      for (const auto& candidate : pending) {
        if (candidate.result && candidate.request_id == request_id) {
          id_in_use = true;
          break;
        }
      }
      if (!id_in_use) break;
      request_id = next_request_id++;
    }
    slot->request_id = request_id;
    slot->result = std::move(result);
    return {RegistrationStatus::kAccepted, request_id};
  }

  bool IsPending(uint64_t request_id) const {
    std::lock_guard<std::mutex> lock(mutex);
    if (!active) return false;
    for (const auto& candidate : pending) {
      if (candidate.result && candidate.request_id == request_id) return true;
    }
    return false;
  }

  bool StoreCompletion(uint64_t request_id, LargeJpegScaleResult completion) {
    std::lock_guard<std::mutex> lock(mutex);
    if (!active) return false;
    for (auto& candidate : pending) {
      if (candidate.result && candidate.request_id == request_id &&
          !candidate.completion.has_value()) {
        candidate.completion.emplace(std::move(completion));
        return true;
      }
    }
    return false;
  }

  void DrainReady() {
    for (;;) {
      std::unique_ptr<MethodResult> result;
      std::optional<LargeJpegScaleResult> completion;
      {
        std::lock_guard<std::mutex> lock(mutex);
        PendingRequest* ready = nullptr;
        for (auto& candidate : pending) {
          if (candidate.result && candidate.completion.has_value()) {
            ready = &candidate;
            break;
          }
        }
        if (ready == nullptr) return;
        result = std::move(ready->result);
        completion.emplace(std::move(*ready->completion));
        ready->completion.reset();
        ready->request_id = 0;
      }
      Deliver(std::move(result), std::move(*completion));
    }
  }

  void Close() {
    {
      std::lock_guard<std::mutex> lock(mutex);
      if (!active) return;
      active = false;
    }
    for (;;) {
      std::unique_ptr<MethodResult> result;
      {
        std::lock_guard<std::mutex> lock(mutex);
        for (auto& candidate : pending) {
          if (!candidate.result) continue;
          result = std::move(candidate.result);
          candidate.completion.reset();
          candidate.request_id = 0;
          break;
        }
      }
      if (!result) return;
      ReplyWithError(std::move(result), "cancelled",
                     "The Windows image scaler is shutting down.");
    }
  }

  static void Deliver(std::unique_ptr<MethodResult> result,
                      LargeJpegScaleResult completion) {
    if (!result) return;
    try {
      if (completion.succeeded()) {
        result->Success(EncodableValue(std::move(completion.png)));
      } else {
        result->Error(completion.error_code, completion.error_message,
                      EncodableValue(nullptr));
      }
    } catch (...) {
      // Never allow a codec or messenger exception to escape the UI message
      // loop.
    }
  }

  mutable std::mutex mutex;
  bool active = true;
  uint64_t next_request_id = 1;
  std::array<PendingRequest, kMaxOutstandingRequests> pending;
};

LargeJpegScalerChannel::LargeJpegScalerChannel(
    flutter::BinaryMessenger* messenger,
    LargeJpegPlatformWake wake_platform,
    LargeJpegScaleOperation operation)
    : state_(std::make_shared<State>()),
      wake_platform_(std::move(wake_platform)),
      platform_thread_(std::this_thread::get_id()) {
  if (!wake_platform_) {
    throw std::invalid_argument(
        "LargeJpegScalerChannel requires a platform-thread wake callback.");
  }
  if (!operation) operation = ScaleJpegOnWorker;

  channel_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "iq.scanid/large_jpeg",
      &flutter::StandardMethodCodec::GetInstance());
  const std::weak_ptr<State> weak_state = state_;
  const auto wake = wake_platform_;
  channel_->SetMethodCallHandler(
      [weak_state, wake, operation = std::move(operation)](
          const flutter::MethodCall<EncodableValue>& call,
          std::unique_ptr<MethodResult> result) mutable {
        const bool is_scale = call.method_name() == "scaleJpeg";
        const bool is_crop = call.method_name() == "cropJpegRegion";
        if (!is_scale && !is_crop) {
          result->NotImplemented();
          return;
        }
        const auto* arguments = std::get_if<EncodableMap>(call.arguments());
        if (arguments == nullptr) {
          ReplyWithError(std::move(result), "invalid_request",
                         "Missing image arguments.");
          return;
        }
        const auto* bytes = GetBytes(*arguments, "bytes");
        const auto width = GetInteger(*arguments, "sourceWidth");
        const auto height = GetInteger(*arguments, "sourceHeight");
        const auto orientation = GetInteger(*arguments, "orientation");
        const auto max_pixels = GetInteger(*arguments, "maxPixels");
        if (bytes == nullptr || !width || !height || !orientation ||
            !max_pixels) {
          ReplyWithError(std::move(result), "invalid_request",
                         "Invalid image parameters.");
          return;
        }
        LargeJpegScaleRequest request;
        request.bytes = *bytes;
        request.source_width = *width;
        request.source_height = *height;
        request.orientation = *orientation;
        request.max_pixels = *max_pixels;
        if (is_scale) {
          const auto target_width = GetInteger(*arguments, "targetWidth");
          const auto target_height = GetInteger(*arguments, "targetHeight");
          if (!target_width || !target_height ||
              !HasSafeScaleBudgets(bytes->size(), *width, *height,
                                   *orientation, *target_width, *target_height,
                                   *max_pixels)) {
            ReplyWithError(std::move(result), "scale_failed",
                           "Image dimensions exceed the safe scaling budget.");
            return;
          }
          request.target_width = *target_width;
          request.target_height = *target_height;
        } else {
          const auto left = GetNumber(*arguments, "left");
          const auto top = GetNumber(*arguments, "top");
          const auto right = GetNumber(*arguments, "right");
          const auto bottom = GetNumber(*arguments, "bottom");
          if (!left || !top || !right || !bottom ||
              !HasSafeCropBudgets(bytes->size(), *width, *height,
                                  *orientation, *left, *top, *right, *bottom,
                                  *max_pixels)) {
            ReplyWithError(std::move(result), "invalid_request",
                           "Invalid bounded JPEG crop parameters.");
            return;
          }
          request.full_resolution_crop = true;
          request.left = *left;
          request.top = *top;
          request.right = *right;
          request.bottom = *bottom;
        }

        auto state = weak_state.lock();
        if (!state) {
          ReplyWithError(std::move(result), "cancelled",
                         "The Windows image scaler is shutting down.");
          return;
        }

        std::optional<uint64_t> request_id;
        try {
          const auto registration = state->Register(result);
          if (registration.status != State::RegistrationStatus::kAccepted) {
            if (registration.status == State::RegistrationStatus::kBusy) {
              ReplyWithError(std::move(result), "busy",
                             "The Windows image scaler is busy.");
            } else {
              ReplyWithError(std::move(result), "cancelled",
                             "The Windows image scaler is shutting down.");
            }
            return;
          }
          request_id = registration.request_id;

          const auto request_token = *request_id;
          const auto worker_operation = operation;
          const auto worker_wake = wake;
          const std::weak_ptr<State> worker_state = state;
          const bool accepted = GetSerialScaleWorker().TrySubmit(
              [worker_state, request_token, request = std::move(request),
               worker_operation, worker_wake]() mutable {
                auto current_state = worker_state.lock();
                if (!current_state || !current_state->IsPending(request_token)) {
                  return;
                }

                LargeJpegScaleResult completion;
                try {
                  completion = worker_operation(request);
                } catch (const std::bad_alloc&) {
                  completion = LargeJpegScaleResult::Failure(
                      "out_of_memory",
                      "Insufficient memory to process this JPEG safely.");
                } catch (...) {
                  completion = LargeJpegScaleResult::Failure(
                      "scale_failed", "The JPEG could not be scaled safely.");
                }

                if (!current_state->StoreCompletion(request_token,
                                                     std::move(completion))) {
                  return;
                }
                // The worker only stores native data and posts a Win32 wake.
                // Flutter's MethodResult is completed later by DrainCompletions
                // on the platform/window thread.
                try {
                  worker_wake();
                } catch (...) {
                  // Results remain in the bounded state map. The runner also
                  // drains them on subsequent window messages, or cancels them
                  // during teardown.
                }
              });
          if (!accepted) {
            if (state->StoreCompletion(
                    request_token,
                    LargeJpegScaleResult::Failure(
                        "busy", "The Windows image scaler is busy."))) {
              state->DrainReady();
            }
          }
        } catch (const std::bad_alloc&) {
          if (request_id) {
            if (state->StoreCompletion(
                    *request_id,
                    LargeJpegScaleResult::Failure(
                        "out_of_memory",
                        "Insufficient memory to process this JPEG safely."))) {
              state->DrainReady();
            }
          } else {
            ReplyWithError(std::move(result), "out_of_memory",
                           "Insufficient memory to process this JPEG safely.");
          }
        } catch (const std::exception&) {
          if (request_id) {
            if (state->StoreCompletion(
                    *request_id,
                    LargeJpegScaleResult::Failure(
                        "scale_failed", "The JPEG could not be scaled safely."))) {
              state->DrainReady();
            }
          } else {
            ReplyWithError(std::move(result), "scale_failed",
                           "The JPEG could not be scaled safely.");
          }
        } catch (...) {
          if (request_id) {
            if (state->StoreCompletion(
                    *request_id,
                    LargeJpegScaleResult::Failure(
                        "scale_failed", "The JPEG could not be scaled safely."))) {
              state->DrainReady();
            }
          } else {
            ReplyWithError(std::move(result), "scale_failed",
                           "The JPEG could not be scaled safely.");
          }
        }
      });
}

LargeJpegScalerChannel::~LargeJpegScalerChannel() {
  // MethodChannel's destructor does not unregister its BinaryMessenger handler.
  if (channel_) channel_->SetMethodCallHandler(nullptr);

  // This owner is created/destroyed on the runner's UI/platform thread, so any
  // in-flight MethodResult is cancelled on the only supported completion
  // thread. Worker jobs own neither the channel nor its messenger/window.
  if (state_) state_->Close();
}

void LargeJpegScalerChannel::DrainCompletions() {
  if (std::this_thread::get_id() != platform_thread_ || !state_) return;
  state_->DrainReady();
}
