#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <flutter/encodable_value.h>

#include <memory>

#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // "compii/overlay": lets the overlay take clicks only while the mouse is
  // over its Yes / No card (the rest of the time clicks pass straight through).
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> overlay_channel_;

  // "compii/island": physical-pixel geometry, displays, focus, foreground
  // restore and click-through for the floating island.
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> island_channel_;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
