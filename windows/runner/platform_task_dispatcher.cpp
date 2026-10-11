#include "platform_task_dispatcher.h"

#include <utility>

PlatformTaskDispatcher::PlatformTaskDispatcher(HWND window)
    : state_(std::make_shared<State>()) {
  state_->window = window;
  state_->active = window != nullptr;
}

PlatformTaskDispatcher::~PlatformTaskDispatcher() { Close(); }

std::function<bool()> PlatformTaskDispatcher::GetWakeCallback() const {
  const std::weak_ptr<State> weak_state = state_;
  return [weak_state] { return PlatformTaskDispatcher::Wake(weak_state); };
}

void PlatformTaskDispatcher::OnWakeMessage() {
  std::lock_guard<std::mutex> lock(state_->mutex);
  state_->wake_pending = false;
}

void PlatformTaskDispatcher::Close() {
  std::lock_guard<std::mutex> lock(state_->mutex);
  state_->active = false;
  state_->wake_pending = false;
  state_->window = nullptr;
}

bool PlatformTaskDispatcher::Wake(const std::weak_ptr<State>& weak_state) {
  const auto state = weak_state.lock();
  if (!state) return false;

  std::lock_guard<std::mutex> lock(state->mutex);
  if (!state->active || state->window == nullptr) return false;
  if (state->wake_pending) return true;
  if (!PostMessage(state->window, kDispatchMessage, 0, 0)) return false;
  state->wake_pending = true;
  return true;
}
