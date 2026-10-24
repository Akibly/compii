#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <algorithm>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();
  // The pointing overlay is a second copy of the app in a small popup window.
  const bool overlay =
      std::find(command_line_arguments.begin(), command_line_arguments.end(),
                "--overlay") != command_line_arguments.end();
  // The floating island is a third copy: transparent, always on top, but able
  // to take keyboard focus (unlike the overlay), so it can be typed into.
  const bool island =
      std::find(command_line_arguments.begin(), command_line_arguments.end(),
                "--island") != command_line_arguments.end();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (overlay) {
    // One transparent, click-through layer over the whole main screen, created
    // once at full size: the cursor buddy is drawn inside it and never has to
    // move a window (moving windows every frame is what makes overlays lag).
    window.SetPopup(true);
    origin = Win32Window::Point(0, 0);
    size = Win32Window::Size(0, 0);  // 0 x 0 = cover the primary monitor
    if (!window.Create(L"Compii overlay", origin, size)) {
      return EXIT_FAILURE;
    }
  } else if (island) {
    // 0 x 0 = the fixed surface Win32Window sizes to the primary work area.
    window.SetPopup(true);
    window.SetIsland(true);
    origin = Win32Window::Point(0, 0);
    size = Win32Window::Size(0, 0);
    if (!window.Create(L"Compii island", origin, size)) {
      return EXIT_FAILURE;
    }
  } else if (!window.Create(L"Compii", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
