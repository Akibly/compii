#include "flutter_window.h"

#include <optional>
#include <string>

#include <flutter/standard_method_codec.h>

#include <winrt/Windows.Data.Xml.Dom.h>
#include <winrt/Windows.UI.Notifications.h>
#include <winrt/base.h>

#include "flutter/generated_plugin_registrant.h"
#include "utils.h"

namespace {

// Flutter sends UTF-8; the toast XML wants UTF-16 with &, < and > escaped.
std::wstring Widen(const std::string& utf8) {
  if (utf8.empty()) return std::wstring();
  int size = ::MultiByteToWideChar(CP_UTF8, 0, utf8.data(),
                                   static_cast<int>(utf8.size()), nullptr, 0);
  std::wstring wide(static_cast<size_t>(size), L'\0');
  ::MultiByteToWideChar(CP_UTF8, 0, utf8.data(),
                        static_cast<int>(utf8.size()), wide.data(), size);
  return wide;
}

std::wstring EscapeXml(const std::wstring& text) {
  std::wstring out;
  out.reserve(text.size());
  for (wchar_t c : text) {
    switch (c) {
      case L'&': out += L"&amp;"; break;
      case L'<': out += L"&lt;"; break;
      case L'>': out += L"&gt;"; break;
      case L'"': out += L"&quot;"; break;
      case L'\'': out += L"&apos;"; break;
      default: out += c;
    }
  }
  return out;
}

std::string MapString(const flutter::EncodableMap& map, const char* key) {
  auto found = map.find(flutter::EncodableValue(key));
  if (found == map.end()) return std::string();
  const auto* text = std::get_if<std::string>(&found->second);
  return text == nullptr ? std::string() : *text;
}

double MapDouble(const flutter::EncodableMap& map, const char* key,
                 double fallback) {
  auto found = map.find(flutter::EncodableValue(key));
  if (found == map.end()) return fallback;
  if (const auto* number = std::get_if<double>(&found->second)) return *number;
  if (const auto* integer = std::get_if<int32_t>(&found->second))
    return static_cast<double>(*integer);
  if (const auto* big = std::get_if<int64_t>(&found->second))
    return static_cast<double>(*big);
  return fallback;
}

// Transparent without WS_EX_LAYERED: the island is layered after its first
// frame (DirectComposition draws nothing in a window layered too early).
void SetClickThrough(HWND hwnd, bool through) {
  LONG ex = GetWindowLong(hwnd, GWL_EXSTYLE);
  ex = through ? (ex | WS_EX_TRANSPARENT) : (ex & ~WS_EX_TRANSPARENT);
  SetWindowLong(hwnd, GWL_EXSTYLE, ex);
}

bool IsOurProcess(HWND hwnd) {
  DWORD pid = 0;
  if (hwnd) GetWindowThreadProcessId(hwnd, &pid);
  return hwnd != nullptr && pid == GetCurrentProcessId();
}

// One island per session: a second copy closes itself instead of leaving two
// capsules on top of each other. Windows releases it if a copy crashes.
HANDLE g_island_mutex = nullptr;

bool ClaimIsland() {
  if (g_island_mutex) return true;
  g_island_mutex = CreateMutexW(nullptr, TRUE, L"Local\\CompiiIsland");
  return g_island_mutex != nullptr && GetLastError() != ERROR_ALREADY_EXISTS;
}

// The main window asks this before it sends a notification: when an island is
// running, telling the user is the island's job and its policy, not ours.
bool IslandIsRunning() {
  HANDLE held = OpenMutexW(SYNCHRONIZE, FALSE, L"Local\\CompiiIsland");
  if (!held) return false;
  CloseHandle(held);
  return true;
}

// Another app owns its whole monitor: a game, a slideshow, a video. A window
// that is merely maximised leaves the taskbar showing, so it does not count.
bool CoversMonitor(HWND hwnd) {
  if (!hwnd || IsOurProcess(hwnd)) return false;
  RECT r;
  if (!GetWindowRect(hwnd, &r)) return false;
  MONITORINFO mi{};
  mi.cbSize = sizeof(mi);
  if (!GetMonitorInfoW(MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST), &mi))
    return false;
  return r.left <= mi.rcMonitor.left && r.top <= mi.rcMonitor.top &&
         r.right >= mi.rcMonitor.right && r.bottom >= mi.rcMonitor.bottom;
}

BOOL CALLBACK CollectDisplay(HMONITOR monitor, HDC, LPRECT, LPARAM data) {
  auto* list = reinterpret_cast<flutter::EncodableList*>(data);
  MONITORINFOEXW info{};
  info.cbSize = sizeof(MONITORINFOEXW);
  if (!GetMonitorInfoW(monitor, &info)) return TRUE;
  const UINT dpi = FlutterDesktopGetDpiForMonitor(monitor);
  const double scale = dpi / 96.0;
  list->push_back(flutter::EncodableValue(flutter::EncodableMap{
      {flutter::EncodableValue("name"),
       flutter::EncodableValue(Utf8FromUtf16(info.szDevice))},
      {flutter::EncodableValue("x"),
       flutter::EncodableValue(static_cast<double>(info.rcMonitor.left))},
      {flutter::EncodableValue("y"),
       flutter::EncodableValue(static_cast<double>(info.rcMonitor.top))},
      {flutter::EncodableValue("width"),
       flutter::EncodableValue(
           static_cast<double>(info.rcMonitor.right - info.rcMonitor.left))},
      {flutter::EncodableValue("height"),
       flutter::EncodableValue(
           static_cast<double>(info.rcMonitor.bottom - info.rcMonitor.top))},
      {flutter::EncodableValue("work_x"),
       flutter::EncodableValue(static_cast<double>(info.rcWork.left))},
      {flutter::EncodableValue("work_y"),
       flutter::EncodableValue(static_cast<double>(info.rcWork.top))},
      {flutter::EncodableValue("work_width"),
       flutter::EncodableValue(
           static_cast<double>(info.rcWork.right - info.rcWork.left))},
      {flutter::EncodableValue("work_height"),
       flutter::EncodableValue(
           static_cast<double>(info.rcWork.bottom - info.rcWork.top))},
      {flutter::EncodableValue("scale"), flutter::EncodableValue(scale)},
      {flutter::EncodableValue("primary"),
       flutter::EncodableValue((info.dwFlags & MONITORINFOF_PRIMARY) != 0)},
  }));
  return TRUE;
}

// The main window belongs to another process with the same runner class.
HWND FindMainWindow() {
  HWND found = FindWindowW(nullptr, L"Compii");
  if (found && !IsOurProcess(found)) return found;
  struct Search {
    HWND result = nullptr;
  } search;
  EnumWindows(
      [](HWND hwnd, LPARAM data) -> BOOL {
        auto* search = reinterpret_cast<Search*>(data);
        if (IsOurProcess(hwnd)) return TRUE;
        wchar_t cls[256] = {};
        GetClassNameW(hwnd, cls, 256);
        if (lstrcmpW(cls, L"FLUTTER_RUNNER_WIN32_WINDOW") != 0) return TRUE;
        wchar_t title[256] = {};
        GetWindowTextW(hwnd, title, 256);
        if (lstrcmpW(title, L"Compii overlay") == 0 ||
            lstrcmpW(title, L"Compii island") == 0) {
          return TRUE;
        }
        search->result = hwnd;
        return FALSE;
      },
      reinterpret_cast<LPARAM>(&search));
  return search.result;
}

// A real Windows toast (notification centre included), no shortcut needed.
void ShowToast(const std::wstring& title, const std::wstring& body) {
  using namespace winrt::Windows::UI::Notifications;
  using namespace winrt::Windows::Data::Xml::Dom;

  std::wstring xml =
      L"<toast><visual><binding template=\"ToastGeneric\"><text>" +
      EscapeXml(title) + L"</text><text>" + EscapeXml(body) +
      L"</text></binding></visual></toast>";
  XmlDocument document;
  document.LoadXml(xml);
  ToastNotification toast(document);
  ToastNotificationManager::CreateToastNotifier(L"Compii").Show(toast);
}

}  // namespace

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
        if (call.method_name() == "toast") {
          const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
          if (args == nullptr) {
            result->Error("bad-args", "A toast needs a title and a body");
            return;
          }
          std::wstring title = Widen(MapString(*args, "title"));
          std::wstring body = Widen(MapString(*args, "body"));
          if (title.empty()) title = L"Compii";
          try {
            ShowToast(title, body);
            result->Success();
          } catch (const winrt::hresult_error& e) {
            result->Error("toast-failed", winrt::to_string(e.message()));
          }
          return;
        }
        if (call.method_name() == "islandAlive") {
          result->Success(flutter::EncodableValue(IslandIsRunning()));
          return;
        }
        if (call.method_name() != "clickThrough") {
          result->NotImplemented();
          return;
        }
        const auto* through = std::get_if<bool>(call.arguments());
        // Only the click-through bit changes; the window stays layered (and so visible).
        SetClickThrough(GetHandle(), through == nullptr || *through);
        result->Success();
      });

  // "compii/island": physical-pixel geometry and window behaviour for the
  // floating island. All positions are physical virtual-desktop pixels, so a
  // monitor to the left of or above the primary one has negative coordinates
  // and mixed DPI needs no conversion on the native side.
  island_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "compii/island",
      &flutter::StandardMethodCodec::GetInstance());
  island_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        const std::string& method = call.method_name();
        HWND hwnd = GetHandle();
        if (method == "claim") {
          result->Success(flutter::EncodableValue(ClaimIsland()));
          return;
        }
        if (method == "bounds") {
          RECT r;
          GetWindowRect(hwnd, &r);
          result->Success(flutter::EncodableValue(flutter::EncodableList{
              flutter::EncodableValue(static_cast<double>(r.left)),
              flutter::EncodableValue(static_cast<double>(r.top)),
              flutter::EncodableValue(static_cast<double>(r.right - r.left)),
              flutter::EncodableValue(static_cast<double>(r.bottom - r.top))}));
          return;
        }
        if (method == "cursor") {
          POINT p;
          GetCursorPos(&p);
          result->Success(flutter::EncodableValue(flutter::EncodableList{
              flutter::EncodableValue(static_cast<double>(p.x)),
              flutter::EncodableValue(static_cast<double>(p.y))}));
          return;
        }
        if (method == "displays") {
          flutter::EncodableList displays;
          EnumDisplayMonitors(nullptr, nullptr, CollectDisplay,
                              reinterpret_cast<LPARAM>(&displays));
          result->Success(flutter::EncodableValue(displays));
          return;
        }
        if (method == "move") {
          const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
          if (args == nullptr) {
            result->Error("bad-args", "move needs x and y");
            return;
          }
          const int x = static_cast<int>(MapDouble(*args, "x", 0));
          const int y = static_cast<int>(MapDouble(*args, "y", 0));
          SetWindowPos(hwnd, nullptr, x, y, 0, 0,
                       SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
          result->Success();
          return;
        }
        if (method == "clickThrough") {
          const auto* through = std::get_if<bool>(call.arguments());
          SetClickThrough(hwnd, through == nullptr || *through);
          result->Success();
          return;
        }
        if (method == "focus") {
          // A hotkey or a tap brought the island forward: it may now be typed
          // into, so raise and activate it without changing its size or place.
          SetWindowPos(hwnd, HWND_TOPMOST, 0, 0, 0, 0,
                       SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
          ShowWindow(hwnd, SW_SHOWNORMAL);
          SetForegroundWindow(hwnd);
          SetFocus(GetWindow(hwnd, GW_CHILD));
          result->Success();
          return;
        }
        if (method == "hide") {
          ShowWindow(hwnd, SW_HIDE);
          result->Success();
          return;
        }
        if (method == "foreground") {
          HWND foreground = GetForegroundWindow();
          if (IsOurProcess(foreground)) foreground = nullptr;
          wchar_t title[512] = {};
          if (foreground) GetWindowTextW(foreground, title, 512);
          result->Success(flutter::EncodableValue(flutter::EncodableMap{
              {flutter::EncodableValue("handle"),
               flutter::EncodableValue(static_cast<double>(
                   reinterpret_cast<uintptr_t>(foreground)))},
              {flutter::EncodableValue("title"),
               flutter::EncodableValue(Utf8FromUtf16(title))},
              {flutter::EncodableValue("fullscreen"),
               flutter::EncodableValue(CoversMonitor(foreground))},
          }));
          return;
        }
        if (method == "restore") {
          const auto* handle = std::get_if<double>(call.arguments());
          HWND target = reinterpret_cast<HWND>(static_cast<uintptr_t>(
              handle == nullptr ? 0.0 : *handle));
          // Only give focus back if the island still has it: if the user has
          // already gone elsewhere, leave their new window alone.
          if (!IsOurProcess(GetForegroundWindow()) || !IsWindow(target)) {
            result->Success(flutter::EncodableValue(false));
            return;
          }
          if (IsIconic(target)) {
            ShowWindow(target, SW_RESTORE);
          } else {
            SetForegroundWindow(target);
          }
          result->Success(flutter::EncodableValue(true));
          return;
        }
        if (method == "revealMain") {
          HWND main = FindMainWindow();
          if (!main) {
            result->Success(flutter::EncodableValue(false));
            return;
          }
          ShowWindow(main, IsIconic(main) ? SW_RESTORE : SW_SHOW);
          SetForegroundWindow(main);
          result->Success(flutter::EncodableValue(true));
          return;
        }
        result->NotImplemented();
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
