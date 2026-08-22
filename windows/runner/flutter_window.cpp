#include "flutter_window.h"

#include <dwmapi.h>
#include <flutter/encodable_value.h>
#include <optional>
#include <shobjidl.h>
#include <string>

#include "flutter/generated_plugin_registrant.h"

#pragma comment(lib, "ole32.lib")

namespace {

constexpr int kPointerHotkeyId = 0x50454E;
constexpr UINT_PTR kHitTestTimerId = 0x50454E01;

#ifndef DWMWA_WINDOW_CORNER_PREFERENCE
#define DWMWA_WINDOW_CORNER_PREFERENCE 33
#endif
#ifndef DWMWCP_DONOTROUND
#define DWMWCP_DONOTROUND 1
#endif
#ifndef WDA_NONE
#define WDA_NONE 0x00000000
#endif
#ifndef WDA_EXCLUDEFROMCAPTURE
#define WDA_EXCLUDEFROMCAPTURE 0x00000011
#endif

bool ReadBool(const flutter::EncodableMap& arguments,
              const char* key,
              bool fallback = false) {
  const auto value = arguments.find(flutter::EncodableValue(key));
  if (value == arguments.end()) {
    return fallback;
  }
  const auto* result = std::get_if<bool>(&value->second);
  return result == nullptr ? fallback : *result;
}

int ReadInt(const flutter::EncodableMap& arguments,
            const char* key,
            int fallback = 0) {
  const auto value = arguments.find(flutter::EncodableValue(key));
  if (value == arguments.end()) {
    return fallback;
  }
  if (const auto* as_int = std::get_if<int32_t>(&value->second)) {
    return static_cast<int>(*as_int);
  }
  if (const auto* as_int64 = std::get_if<int64_t>(&value->second)) {
    return static_cast<int>(*as_int64);
  }
  if (const auto* as_double = std::get_if<double>(&value->second)) {
    return static_cast<int>(*as_double);
  }
  return fallback;
}

std::string ReadString(const flutter::EncodableMap& arguments,
                       const char* key) {
  const auto value = arguments.find(flutter::EncodableValue(key));
  if (value == arguments.end()) {
    return {};
  }
  if (const auto* as_string = std::get_if<std::string>(&value->second)) {
    return *as_string;
  }
  return {};
}

std::wstring Utf8ToWide(const std::string& value) {
  if (value.empty()) {
    return {};
  }
  const int size = MultiByteToWideChar(CP_UTF8, 0, value.data(),
                                       static_cast<int>(value.size()), nullptr,
                                       0);
  if (size <= 0) {
    return {};
  }
  std::wstring wide(static_cast<size_t>(size), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, value.data(), static_cast<int>(value.size()),
                      wide.data(), size);
  return wide;
}

std::string WideToUtf8(const std::wstring& value) {
  if (value.empty()) {
    return {};
  }
  const int size =
      WideCharToMultiByte(CP_UTF8, 0, value.data(),
                          static_cast<int>(value.size()), nullptr, 0, nullptr,
                          nullptr);
  if (size <= 0) {
    return {};
  }
  std::string utf8(static_cast<size_t>(size), '\0');
  WideCharToMultiByte(CP_UTF8, 0, value.data(), static_cast<int>(value.size()),
                      utf8.data(), size, nullptr, nullptr);
  return utf8;
}

std::vector<RECT> ReadHitTestRects(const flutter::EncodableMap& arguments) {
  std::vector<RECT> rects;
  const auto value = arguments.find(flutter::EncodableValue("rects"));
  if (value == arguments.end()) {
    return rects;
  }
  const auto* list = std::get_if<flutter::EncodableList>(&value->second);
  if (list == nullptr) {
    return rects;
  }
  for (const auto& entry : *list) {
    const auto* map = std::get_if<flutter::EncodableMap>(&entry);
    if (map == nullptr) {
      continue;
    }
    auto read_int = [&](const char* key, LONG fallback) -> LONG {
      const auto it = map->find(flutter::EncodableValue(key));
      if (it == map->end()) {
        return fallback;
      }
      if (const auto* as_int = std::get_if<int32_t>(&it->second)) {
        return static_cast<LONG>(*as_int);
      }
      if (const auto* as_int64 = std::get_if<int64_t>(&it->second)) {
        return static_cast<LONG>(*as_int64);
      }
      if (const auto* as_double = std::get_if<double>(&it->second)) {
        return static_cast<LONG>(*as_double);
      }
      return fallback;
    };
    RECT rect{};
    rect.left = read_int("left", 0);
    rect.top = read_int("top", 0);
    rect.right = read_int("right", 0);
    rect.bottom = read_int("bottom", 0);
    if (rect.right > rect.left && rect.bottom > rect.top) {
      rects.push_back(rect);
    }
  }
  return rects;
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
  native_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "pen/native",
          &flutter::StandardMethodCodec::GetInstance());
  native_channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        const auto* arguments =
            std::get_if<flutter::EncodableMap>(call.arguments());
        if (call.method_name() == "fitOverlay") {
          if (arguments == nullptr) {
            result->Error("bad_args", "fitOverlay requires arguments");
            return;
          }
          result->Success(flutter::EncodableValue(FitOverlayToDisplay(
              ReadBool(*arguments, "useCursorDisplay"),
              ReadBool(*arguments, "coverTaskbar"))));
          return;
        }
        if (call.method_name() == "setPassThrough") {
          if (arguments == nullptr) {
            result->Error("bad_args", "setPassThrough requires arguments");
            return;
          }
          result->Success(flutter::EncodableValue(
              SetPassThrough(ReadBool(*arguments, "enabled"))));
          return;
        }
        if (call.method_name() == "setHitTestRects") {
          if (arguments == nullptr) {
            result->Error("bad_args", "setHitTestRects requires arguments");
            return;
          }
          result->Success(flutter::EncodableValue(
              SetHitTestRects(ReadHitTestRects(*arguments))));
          return;
        }
        if (call.method_name() == "setPointerMode") {
          if (arguments == nullptr) {
            result->Error("bad_args", "setPointerMode requires arguments");
            return;
          }
          result->Success(flutter::EncodableValue(
              SetPointerMode(ReadBool(*arguments, "enabled"))));
          return;
        }
        if (call.method_name() == "captureScreenRect") {
          if (arguments == nullptr) {
            result->Error("bad_args", "captureScreenRect requires arguments");
            return;
          }
          const int width = ReadInt(*arguments, "width");
          const int height = ReadInt(*arguments, "height");
          int left = ReadInt(*arguments, "left");
          int top = ReadInt(*arguments, "top");
          if (ReadBool(*arguments, "centerOnCursor")) {
            POINT cursor{};
            if (GetCursorPos(&cursor)) {
              left = cursor.x - width / 2;
              top = cursor.y - height / 2;
            }
          }
          result->Success(CaptureScreenRect(left, top, width, height));
          return;
        }
        if (call.method_name() == "pickDirectory") {
          const flutter::EncodableMap empty;
          const flutter::EncodableMap& args =
              arguments == nullptr ? empty : *arguments;
          result->Success(PickDirectory(ReadString(args, "dialogTitle"),
                                        ReadString(args, "initialDirectory")));
          return;
        }
        result->NotImplemented();
      });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  // Keep the pointer hotkey available for the whole session so users can
  // toggle desktop click-through without first entering pass-through.
  if (GetHandle() != nullptr) {
    pointer_hotkey_registered_ =
        RegisterHotKey(GetHandle(), kPointerHotkeyId,
                       MOD_CONTROL | MOD_SHIFT | MOD_NOREPEAT, 'P') != FALSE;
  }

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
  StopHitTestTimer();
  SetPassThrough(false);
  SetPointerMode(false);
  native_channel_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (message == WM_NCCALCSIZE && wparam == TRUE && overlay_style_applied_) {
    // Client area fills the entire window — eliminates residual NC chrome gaps.
    return 0;
  }
  if (message == WM_HOTKEY &&
      static_cast<int>(wparam) == kPointerHotkeyId) {
    if (native_channel_) {
      native_channel_->InvokeMethod("togglePointerMode", nullptr);
    }
    return 0;
  }
  if (message == WM_DESTROY && pointer_hotkey_registered_) {
    UnregisterHotKey(hwnd, kPointerHotkeyId);
    pointer_hotkey_registered_ = false;
  }
  if (message == WM_DPICHANGED && has_last_overlay_bounds_) {
    // Prefer the last explicit overlay fit over the system-suggested rect so
    // Per-Monitor V2 DPI changes do not leave gaps at the display edges.
    const RECT& bounds = last_overlay_bounds_;
    SetWindowPos(hwnd, HWND_TOPMOST, bounds.left, bounds.top,
                 bounds.right - bounds.left, bounds.bottom - bounds.top,
                 SWP_NOACTIVATE | SWP_FRAMECHANGED | SWP_SHOWWINDOW);
    ResizeChildToClient();
    return 0;
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
    case WM_SIZE:
      ResizeChildToClient();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

void FlutterWindow::EnsureBorderlessOverlayStyle() {
  const HWND window = GetHandle();
  if (window == nullptr) {
    return;
  }
  LONG_PTR style = GetWindowLongPtr(window, GWL_STYLE);
  const LONG_PTR desired =
      (style & ~(WS_CAPTION | WS_THICKFRAME | WS_MINIMIZEBOX | WS_MAXIMIZEBOX |
                 WS_SYSMENU | WS_BORDER | WS_DLGFRAME | WS_OVERLAPPED)) |
      WS_POPUP;
  if (style != desired) {
    SetWindowLongPtr(window, GWL_STYLE, desired);
  }
  LONG_PTR ex_style = GetWindowLongPtr(window, GWL_EXSTYLE);
  ex_style |= WS_EX_LAYERED | WS_EX_TOPMOST;
  ex_style &= ~(WS_EX_CLIENTEDGE | WS_EX_WINDOWEDGE | WS_EX_DLGMODALFRAME |
                WS_EX_STATICEDGE | WS_EX_APPWINDOW);
  SetWindowLongPtr(window, GWL_EXSTYLE, ex_style);
  // Fully opaque layered window; transparency is handled by Flutter content.
  SetLayeredWindowAttributes(window, 0, 255, LWA_ALPHA);
  SetWindowDisplayAffinity(window, WDA_NONE);

  MARGINS margins = {-1, -1, -1, -1};
  DwmExtendFrameIntoClientArea(window, &margins);
  const DWORD corner = DWMWCP_DONOTROUND;
  DwmSetWindowAttribute(window, DWMWA_WINDOW_CORNER_PREFERENCE, &corner,
                        sizeof(corner));
  overlay_style_applied_ = true;
}

void FlutterWindow::SetExcludeFromCapture(bool exclude) {
  const HWND window = GetHandle();
  if (window == nullptr) {
    return;
  }
  SetWindowDisplayAffinity(window,
                           exclude ? WDA_EXCLUDEFROMCAPTURE : WDA_NONE);
}

bool FlutterWindow::FitOverlayToDisplay(bool use_cursor_display,
                                        bool cover_taskbar) {
  POINT target{};
  if (use_cursor_display) {
    if (!GetCursorPos(&target)) {
      return false;
    }
  } else {
    RECT window_rect{};
    if (!GetWindowRect(GetHandle(), &window_rect)) {
      return false;
    }
    target.x = window_rect.left + (window_rect.right - window_rect.left) / 2;
    target.y = window_rect.top + (window_rect.bottom - window_rect.top) / 2;
  }

  const HMONITOR monitor =
      MonitorFromPoint(target, MONITOR_DEFAULTTONEAREST);
  MONITORINFO monitor_info{};
  monitor_info.cbSize = sizeof(monitor_info);
  if (!GetMonitorInfo(monitor, &monitor_info)) {
    return false;
  }

  EnsureBorderlessOverlayStyle();

  // cover_taskbar=true uses the full physical monitor. Otherwise use the work
  // area, but still remove chrome so the Flutter surface can sit flush.
  const RECT bounds =
      cover_taskbar ? monitor_info.rcMonitor : monitor_info.rcWork;
  const int width = bounds.right - bounds.left;
  const int height = bounds.bottom - bounds.top;
  last_overlay_bounds_ = bounds;
  has_last_overlay_bounds_ = true;

  auto apply_bounds = [&]() -> bool {
    if (!SetWindowPos(GetHandle(), HWND_TOPMOST, bounds.left, bounds.top, width,
                      height,
                      SWP_NOACTIVATE | SWP_FRAMECHANGED | SWP_SHOWWINDOW)) {
      return false;
    }
    ResizeChildToClient();
    return true;
  };

  if (!apply_bounds()) {
    return false;
  }

  // WM_DPICHANGED can apply its suggested rectangle during the first move.
  // A second pass uses the destination monitor's now-current DPI.
  RECT applied_bounds{};
  if (GetWindowRect(GetHandle(), &applied_bounds) &&
      (applied_bounds.left != bounds.left ||
       applied_bounds.top != bounds.top ||
       applied_bounds.right != bounds.right ||
       applied_bounds.bottom != bounds.bottom)) {
    const bool ok = apply_bounds();
    if (ok) {
      last_overlay_bounds_ = bounds;
    }
    return ok;
  }

  // Verify client area matches intended size (no leftover NC chrome).
  RECT client = GetClientArea();
  if ((client.right - client.left) != width ||
      (client.bottom - client.top) != height) {
    apply_bounds();
  }
  return true;
}

void FlutterWindow::ApplyClickThrough(bool enabled) {
  const HWND window = GetHandle();
  if (window == nullptr || click_through_active_ == enabled) {
    return;
  }
  LONG_PTR extended_style = GetWindowLongPtr(window, GWL_EXSTYLE);
  if (enabled) {
    extended_style |= WS_EX_TRANSPARENT | WS_EX_LAYERED;
  } else {
    extended_style &= ~WS_EX_TRANSPARENT;
    extended_style |= WS_EX_LAYERED;
  }
  SetWindowLongPtr(window, GWL_EXSTYLE, extended_style);
  SetWindowPos(window, nullptr, 0, 0, 0, 0,
               SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE |
                   SWP_FRAMECHANGED);
  click_through_active_ = enabled;
}

void FlutterWindow::UpdatePassThroughForCursor() {
  if (!pass_through_enabled_) {
    ApplyClickThrough(false);
    return;
  }
  POINT cursor{};
  if (!GetCursorPos(&cursor)) {
    ApplyClickThrough(true);
    return;
  }
  POINT client = cursor;
  if (!ScreenToClient(GetHandle(), &client)) {
    ApplyClickThrough(true);
    return;
  }
  bool over_interactive = false;
  for (const RECT& rect : hit_test_rects_) {
    if (PtInRect(&rect, client)) {
      over_interactive = true;
      break;
    }
  }
  ApplyClickThrough(!over_interactive);
}

void CALLBACK FlutterWindow::HitTestTimerProc(HWND hwnd, UINT message,
                                              UINT_PTR id, DWORD time) {
  auto* window = reinterpret_cast<Win32Window*>(
      GetWindowLongPtr(hwnd, GWLP_USERDATA));
  if (window == nullptr) {
    return;
  }
  static_cast<FlutterWindow*>(window)->UpdatePassThroughForCursor();
}

void FlutterWindow::StartHitTestTimer() {
  const HWND window = GetHandle();
  if (window == nullptr || hit_test_timer_id_ != 0) {
    return;
  }
  hit_test_timer_id_ =
      SetTimer(window, kHitTestTimerId, 16, HitTestTimerProc);
}

void FlutterWindow::StopHitTestTimer() {
  const HWND window = GetHandle();
  if (window != nullptr && hit_test_timer_id_ != 0) {
    KillTimer(window, hit_test_timer_id_);
  }
  hit_test_timer_id_ = 0;
}

bool FlutterWindow::SetHitTestRects(const std::vector<RECT>& rects) {
  hit_test_rects_ = rects;
  if (pass_through_enabled_) {
    UpdatePassThroughForCursor();
  }
  return true;
}

bool FlutterWindow::SetPassThrough(bool enabled) {
  const HWND window = GetHandle();
  if (window == nullptr) {
    return false;
  }
  pass_through_enabled_ = enabled;
  if (enabled) {
    StartHitTestTimer();
    UpdatePassThroughForCursor();
  } else {
    StopHitTestTimer();
    ApplyClickThrough(false);
  }
  return true;
}

bool FlutterWindow::SetPointerMode(bool enabled) {
  // Compatibility shim: enabled means full-window click-through (no hit
  // regions). Disabled clears click-through for shutdown / recovery.
  if (enabled) {
    hit_test_rects_.clear();
    return SetPassThrough(true);
  }
  pass_through_enabled_ = false;
  StopHitTestTimer();
  ApplyClickThrough(false);
  return true;
}

flutter::EncodableValue FlutterWindow::CaptureScreenRect(int left, int top,
                                                         int width,
                                                         int height) {
  flutter::EncodableMap result;
  result[flutter::EncodableValue("ok")] = flutter::EncodableValue(false);
  if (width <= 0 || height <= 0 || width > 8192 || height > 8192) {
    return flutter::EncodableValue(result);
  }

  HDC screen_dc = GetDC(nullptr);
  HDC memory_dc = CreateCompatibleDC(screen_dc);
  BITMAPINFO bmi{};
  bmi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  bmi.bmiHeader.biWidth = width;
  bmi.bmiHeader.biHeight = -height;  // top-down
  bmi.bmiHeader.biPlanes = 1;
  bmi.bmiHeader.biBitCount = 32;
  bmi.bmiHeader.biCompression = BI_RGB;
  void* bits = nullptr;
  HBITMAP bitmap =
      CreateDIBSection(memory_dc, &bmi, DIB_RGB_COLORS, &bits, nullptr, 0);
  bool ok = false;
  std::vector<uint8_t> pixels;
  if (bitmap != nullptr && bits != nullptr) {
    const HGDIOBJ old = SelectObject(memory_dc, bitmap);
    SetExcludeFromCapture(true);
    ok = BitBlt(memory_dc, 0, 0, width, height, screen_dc, left, top,
                SRCCOPY | CAPTUREBLT) != FALSE;
    if (!ok) {
      ok = BitBlt(memory_dc, 0, 0, width, height, screen_dc, left, top,
                  SRCCOPY) != FALSE;
    }
    SetExcludeFromCapture(false);
    SelectObject(memory_dc, old);
    if (ok) {
      const size_t byte_count = static_cast<size_t>(width) *
                                static_cast<size_t>(height) * 4;
      pixels.resize(byte_count);
      memcpy(pixels.data(), bits, byte_count);
      // Convert BGRA → RGBA and force opaque alpha. Screen BitBlt typically
      // leaves alpha at 0, which Flutter paints as fully transparent.
      for (size_t i = 0; i + 3 < byte_count; i += 4) {
        std::swap(pixels[i], pixels[i + 2]);
        pixels[i + 3] = 255;
      }
    }
  }

  if (bitmap != nullptr) {
    DeleteObject(bitmap);
  }
  DeleteDC(memory_dc);
  ReleaseDC(nullptr, screen_dc);

  result[flutter::EncodableValue("ok")] = flutter::EncodableValue(ok);
  if (ok) {
    result[flutter::EncodableValue("width")] = flutter::EncodableValue(width);
    result[flutter::EncodableValue("height")] = flutter::EncodableValue(height);
    result[flutter::EncodableValue("bytes")] =
        flutter::EncodableValue(pixels);
  }
  return flutter::EncodableValue(result);
}

flutter::EncodableValue FlutterWindow::PickDirectory(
    const std::string& dialog_title,
    const std::string& initial_directory) {
  // Distinguishes cancel vs failure so Dart does not open a second picker.
  flutter::EncodableMap result;
  result[flutter::EncodableValue("ok")] = flutter::EncodableValue(false);
  result[flutter::EncodableValue("cancelled")] = flutter::EncodableValue(false);
  result[flutter::EncodableValue("path")] = flutter::EncodableValue("");

  IFileOpenDialog* dialog = nullptr;
  HRESULT hr =
      CoCreateInstance(CLSID_FileOpenDialog, nullptr, CLSCTX_INPROC_SERVER,
                       IID_PPV_ARGS(&dialog));
  if (FAILED(hr) || dialog == nullptr) {
    return flutter::EncodableValue(result);
  }

  DWORD options = 0;
  if (SUCCEEDED(dialog->GetOptions(&options))) {
    dialog->SetOptions(options | FOS_PICKFOLDERS | FOS_FORCEFILESYSTEM |
                       FOS_NOCHANGEDIR);
  }

  const std::wstring title = Utf8ToWide(
      dialog_title.empty() ? "Choose folder" : dialog_title);
  if (!title.empty()) {
    dialog->SetTitle(title.c_str());
  }

  if (!initial_directory.empty()) {
    const std::wstring folder = Utf8ToWide(initial_directory);
    IShellItem* item = nullptr;
    if (SUCCEEDED(SHCreateItemFromParsingName(folder.c_str(), nullptr,
                                              IID_PPV_ARGS(&item))) &&
        item != nullptr) {
      dialog->SetFolder(item);
      item->Release();
    }
  }

  // Drop topmost briefly so the picker is usable above the overlay.
  const HWND window = GetHandle();
  const LONG_PTR previous_ex =
      window == nullptr ? 0 : GetWindowLongPtr(window, GWL_EXSTYLE);
  if (window != nullptr) {
    SetWindowLongPtr(window, GWL_EXSTYLE, previous_ex & ~WS_EX_TOPMOST);
    SetWindowPos(window, HWND_NOTOPMOST, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_FRAMECHANGED);
  }

  hr = dialog->Show(window);
  std::string selected;
  if (SUCCEEDED(hr)) {
    IShellItem* result_item = nullptr;
    if (SUCCEEDED(dialog->GetResult(&result_item)) && result_item != nullptr) {
      PWSTR path = nullptr;
      if (SUCCEEDED(result_item->GetDisplayName(SIGDN_FILESYSPATH, &path)) &&
          path != nullptr) {
        selected = WideToUtf8(path);
        CoTaskMemFree(path);
      }
      result_item->Release();
    }
  } else if (hr == HRESULT_FROM_WIN32(ERROR_CANCELLED)) {
    result[flutter::EncodableValue("cancelled")] =
        flutter::EncodableValue(true);
  }
  dialog->Release();

  if (window != nullptr) {
    SetWindowLongPtr(window, GWL_EXSTYLE, previous_ex | WS_EX_TOPMOST);
    SetWindowPos(window, HWND_TOPMOST, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_FRAMECHANGED);
  }

  if (!selected.empty()) {
    result[flutter::EncodableValue("ok")] = flutter::EncodableValue(true);
    result[flutter::EncodableValue("cancelled")] =
        flutter::EncodableValue(false);
    result[flutter::EncodableValue("path")] =
        flutter::EncodableValue(selected);
  }
  return flutter::EncodableValue(result);
}
