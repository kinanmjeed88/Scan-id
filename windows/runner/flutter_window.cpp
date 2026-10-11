#include "flutter_window.h"

#include <optional>

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  platform_task_dispatcher_ =
      std::make_unique<PlatformTaskDispatcher>(GetHandle());
  large_jpeg_scaler_channel_ = std::make_unique<LargeJpegScalerChannel>(
      flutter_controller_->engine()->messenger(),
      platform_task_dispatcher_->GetWakeCallback());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  large_jpeg_scaler_channel_.reset();
  if (platform_task_dispatcher_) platform_task_dispatcher_->Close();
  platform_task_dispatcher_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (message == PlatformTaskDispatcher::kDispatchMessage) {
    if (platform_task_dispatcher_) platform_task_dispatcher_->OnWakeMessage();
    if (large_jpeg_scaler_channel_) {
      large_jpeg_scaler_channel_->DrainCompletions();
    }
    return 0;
  }

  // Also drain in case PostMessage could not enqueue a wake while the window's
  // message queue was temporarily saturated. Results remain bounded in the
  // channel until this next platform-thread dispatch or shutdown cancellation.
  if (large_jpeg_scaler_channel_) {
    large_jpeg_scaler_channel_->DrainCompletions();
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
