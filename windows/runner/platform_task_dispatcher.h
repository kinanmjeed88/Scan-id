#ifndef RUNNER_PLATFORM_TASK_DISPATCHER_H_
#define RUNNER_PLATFORM_TASK_DISPATCHER_H_

#include <windows.h>

#include <functional>
#include <memory>
#include <mutex>

/// A bounded wake-up bridge from worker threads to the Win32 window thread.
/// It posts no task payloads; owners drain their own bounded completion state
/// after receiving the wake message.
class PlatformTaskDispatcher {
 public:
  static constexpr UINT kDispatchMessage = WM_APP + 0x134;

  explicit PlatformTaskDispatcher(HWND window);
  ~PlatformTaskDispatcher();

  PlatformTaskDispatcher(const PlatformTaskDispatcher&) = delete;
  PlatformTaskDispatcher& operator=(const PlatformTaskDispatcher&) = delete;

  /// Returns a callback safe to retain on a worker thread.
  std::function<bool()> GetWakeCallback() const;

  /// Acknowledge the custom window message before draining completion state.
  void OnWakeMessage();

  /// Stop accepting wakes before the window or Flutter engine is destroyed.
  void Close();

 private:
  struct State {
    std::mutex mutex;
    HWND window = nullptr;
    bool active = false;
    bool wake_pending = false;
  };

  static bool Wake(const std::weak_ptr<State>& state);

  std::shared_ptr<State> state_;
};

#endif  // RUNNER_PLATFORM_TASK_DISPATCHER_H_
