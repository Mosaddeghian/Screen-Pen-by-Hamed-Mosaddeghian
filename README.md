# Screen pen by Hamed Mosaddeghian

Screen pen by Hamed Mosaddeghian is a lightweight Flutter annotation overlay inspired by the Epic Pen
walkthrough in `Sample Materials`. Windows is the first target; the drawing
model is intentionally portable for later tablet builds.

## Download (portable version)

No installation needed — just download, unzip, and run:

1. Go to the [Releases page](https://github.com/Mosaddeghian/Screen-Pen-by-Hamed-Mosaddeghian/releases/latest).
2. Download `ScreenPen-vX.Y.Z-portable-win64.zip` from the latest release.
3. Right-click the zip and choose **Extract All**.
4. Open the extracted folder and double-click `pen.exe`.

If Windows shows a security warning for an unsigned app, click
**More info → Run anyway**.

## Implemented

- Transparent, frameless, always-on-top Windows window.
- Per-monitor overlay sizing with DPI-aware native monitor bounds. Drag the
  toolbar handle to move the overlay to another display.
- Screen, Whiteboard, and Blackboard canvases with independent drawing memory.
- Vector pen, translucent highlighter, text, line, and rectangle objects.
- Separate tool slots with independent color, thickness, font size, and
  filled-rectangle state. Duplicate slots can be added from the sidebar.
- Click-or-drag object eraser, per-canvas undo, trash, screenshot, and a
  high-visibility pointer halo.
- Click-through pointer mode for normal Windows interaction; use
  `Ctrl+Shift+P` to return to annotation mode.
- Compact collapsible sidebar, selected-width controls, quick colors, full RGB
  palette, visible Exit action, and settings for taskbar coverage, persistence,
  and screenshot folder.
- Keyboard shortcuts: `Ctrl+Shift+W`, `Ctrl+Shift+B`, `Ctrl+Shift+Z`,
  `Ctrl+Shift+S`, `Ctrl+Shift+H`, `Ctrl+Shift+P`, and `Ctrl+Shift+Q`.

## Run

```powershell
flutter pub get
flutter run -d windows
```

For Windows plugin builds, enable Windows Developer Mode once so Flutter can
create plugin symlinks:

```powershell
start ms-settings:developers
```

Then build:

```powershell
flutter build windows --release
```

## Validate

```powershell
flutter analyze
flutter test
```
