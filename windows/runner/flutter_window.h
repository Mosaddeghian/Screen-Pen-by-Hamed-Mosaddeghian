#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <string>
#include <vector>

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
  bool FitOverlayToDisplay(bool use_cursor_display, bool cover_taskbar);
  bool SetPassThrough(bool enabled);
  bool SetHitTestRects(const std::vector<RECT>& rects);
  bool SetPointerMode(bool enabled);
  void ApplyClickThrough(bool enabled);
  void EnsureBorderlessOverlayStyle();
  void SetExcludeFromCapture(bool exclude);
  void StartHitTestTimer();
  void StopHitTestTimer();
  void UpdatePassThroughForCursor();
  flutter::EncodableValue CaptureScreenRect(int left, int top, int width,
                                            int height);
  flutter::EncodableValue PickDirectory(const std::string& dialog_title,
                                        const std::string& initial_directory);
  static void CALLBACK HitTestTimerProc(HWND hwnd, UINT message, UINT_PTR id,
                                        DWORD time);

  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      native_channel_;
  bool pointer_hotkey_registered_ = false;
  bool pass_through_enabled_ = false;
  bool click_through_active_ = false;
  bool overlay_style_applied_ = false;
  UINT_PTR hit_test_timer_id_ = 0;
  std::vector<RECT> hit_test_rects_;
  RECT last_overlay_bounds_{};
  bool has_last_overlay_bounds_ = false;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
