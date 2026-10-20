#include "flutter_window.h"

#include <optional>

#include <flutter/standard_method_codec.h>

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

  overlay_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "compii/overlay",
      &flutter::StandardMethodCodec::GetInstance());
  overlay_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() == "cursor" || call.method_name() == "origin") {
          // Physical pixels: the cursor relative to this window, or the window's top left
          // on the virtual desktop (monitors left of or above the main one are negative).
          RECT r;
          GetWindowRect(GetHandle(), &r);
          POINT p = {r.left, r.top};
          if (call.method_name() == "cursor") {
            GetCursorPos(&p);
            p.x -= r.left;
            p.y -= r.top;
          }
          result->Success(flutter::EncodableValue(flutter::EncodableList{
              flutter::EncodableValue(static_cast<double>(p.x)), flutter::EncodableValue(static_cast<double>(p.y))}));
          return;
        }
        if (call.method_name() != "clickThrough") {
          result->NotImplemented();
          return;
        }
        const auto* through = std::get_if<bool>(call.arguments());
        HWND hwnd = GetHandle();
        LONG ex = GetWindowLong(hwnd, GWL_EXSTYLE);
        // Only the click-through bit changes; the window stays layered (and so visible).
        ex = (through == nullptr || *through) ? (ex | WS_EX_TRANSPARENT) : (ex & ~WS_EX_TRANSPARENT);
        SetWindowLong(hwnd, GWL_EXSTYLE, ex);
        result->Success();
      });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  // Started with Windows (--background): stay hidden; Alt+Space or the tray brings it up.
  const bool background = wcsstr(GetCommandLineW(), L"--background") != nullptr;
  flutter_controller_->engine()->SetNextFrameCallback([this, background]() {
    if (!background) this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
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
