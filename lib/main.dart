import 'dart:async';
import 'dart:convert';
import 'dart:ffi' hide Size;
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

const MethodChannel _nativeChannel = MethodChannel('pen/native');

/// Shown in Settings. Keep in sync with `pubspec.yaml` and `CHANGELOG.md`.
const kAppVersion = '1.7.1';

const int _vkShift = 0x10;
const int _shiftKeyDownBit = 0x8000;

typedef _GetAsyncKeyStateC = Int16 Function(Int32 virtualKey);
typedef _GetAsyncKeyStateDart = int Function(int virtualKey);

_GetAsyncKeyStateDart? _windowsGetAsyncKeyState;

bool _isShiftLogicalKey(LogicalKeyboardKey key) =>
    key == LogicalKeyboardKey.shift ||
    key == LogicalKeyboardKey.shiftLeft ||
    key == LogicalKeyboardKey.shiftRight;

/// Shift currently held, even if this overlay does not have keyboard focus.
///
/// Overlay windows often sit above other apps without taking keyboard focus,
/// so Flutter's own key state can miss Shift. On Windows we read the OS key
/// state instead. Widget tests keep using Flutter's key state.
bool isShiftHeld() {
  final fromFlutter = HardwareKeyboard.instance.isShiftPressed;
  if (!Platform.isWindows || Platform.environment.containsKey('FLUTTER_TEST')) {
    return fromFlutter;
  }
  return _windowsShiftKeyDown() ?? fromFlutter;
}

bool? _windowsShiftKeyDown() {
  try {
    _windowsGetAsyncKeyState ??= DynamicLibrary.open('user32.dll')
        .lookupFunction<_GetAsyncKeyStateC, _GetAsyncKeyStateDart>(
          'GetAsyncKeyState',
        );
    return (_windowsGetAsyncKeyState!(_vkShift) & _shiftKeyDownBit) != 0;
  } catch (_) {
    return null;
  }
}

/// Dart fallback overlay bounds. Prefer native `fitOverlay` on Windows.
///
/// When [coverTaskbar] is true, never pair the work-area origin with a larger
/// size (left/top taskbar gap). Anchor to the monitor bottom-right implied by
/// screen_retriever's size formula and expand to fully cover the work area.
Rect overlayBoundsForDisplay({
  required Offset workOrigin,
  required Size workSize,
  required Size displaySize,
  required bool coverTaskbar,
}) {
  if (!coverTaskbar) {
    return Rect.fromLTWH(
      workOrigin.dx,
      workOrigin.dy,
      workSize.width,
      workSize.height,
    );
  }
  final monitorRight = workOrigin.dx + displaySize.width;
  final monitorBottom = workOrigin.dy + displaySize.height;
  final width = math.max(displaySize.width, workSize.width);
  final height = math.max(displaySize.height, workSize.height);
  final left = math.min(workOrigin.dx, monitorRight - width);
  final top = math.min(workOrigin.dy, monitorBottom - height);
  final right = math.max(monitorRight, workOrigin.dx + workSize.width);
  final bottom = math.max(monitorBottom, workOrigin.dy + workSize.height);
  return Rect.fromLTRB(left, top, right, bottom);
}

/// Returns [end] aligned horizontally or vertically with [start].
///
/// The dominant drag direction determines the axis, which lets users draw
/// straight lines without needing to position the pointer perfectly.
Offset constrainLineToAxis(Offset start, Offset end) {
  final delta = end - start;
  return delta.dx.abs() >= delta.dy.abs()
      ? Offset(end.dx, start.dy)
      : Offset(start.dx, end.dy);
}

const Color kCandleBullColor = Color(0xff46d17d);
const Color kCandleBearColor = Color(0xffff4d67);
const String kGreenCandleSlotId = 'candle-green';
const String kRedCandleSlotId = 'candle-red';

/// Drag up (smaller screen Y) is bullish; drag down is bearish.
bool candleDragIsBullish(Offset start, Offset end) => end.dy < start.dy;

double defaultCandleWickLength(double bodyHeight, double thickness) {
  final height = bodyHeight.abs();
  return math.max(thickness, math.max(4, height * 0.15));
}

/// Body from a drag: vertical span is open/close; width is at least [thickness].
CandleSpec candleSpecFromBodyDrag(
  Offset start,
  Offset end,
  double thickness, {
  bool includeDefaultWicks = true,
}) {
  final width = math.max(thickness, (end.dx - start.dx).abs());
  final x = (start.dx + end.dx) / 2 - width / 2;
  final openY = start.dy;
  final closeY = end.dy;
  final bodyTop = math.min(openY, closeY);
  final bodyBottom = math.max(openY, closeY);
  final wick = includeDefaultWicks
      ? defaultCandleWickLength(bodyBottom - bodyTop, thickness)
      : 0.0;
  return CandleSpec(
    x: x,
    width: width,
    openY: openY,
    closeY: closeY,
    highY: bodyTop - wick,
    lowY: bodyBottom + wick,
  );
}

CandleSpec applyCandleWicks(CandleSpec body, Offset a, Offset b) {
  final bodyTop = math.min(body.openY, body.closeY);
  final bodyBottom = math.max(body.openY, body.closeY);
  return CandleSpec(
    x: body.x,
    width: body.width,
    openY: body.openY,
    closeY: body.closeY,
    highY: math.min(bodyTop, math.min(a.dy, b.dy)),
    lowY: math.max(bodyBottom, math.max(a.dy, b.dy)),
  );
}

CandleSpec defaultCandleAt(Offset point, double thickness) {
  final bodyHeight = math.max(16.0, thickness * 4);
  final openY = point.dy + bodyHeight / 2;
  final closeY = point.dy - bodyHeight / 2;
  return candleSpecFromBodyDrag(
    Offset(point.dx, openY),
    Offset(point.dx, closeY),
    thickness,
  );
}

Rect candleGroupBounds(Iterable<CandleSpec> candles) {
  var left = double.infinity;
  var top = double.infinity;
  var right = double.negativeInfinity;
  var bottom = double.negativeInfinity;
  for (final candle in candles) {
    left = math.min(left, candle.x);
    right = math.max(right, candle.x + candle.width);
    top = math.min(top, candle.highY);
    bottom = math.max(bottom, candle.lowY);
  }
  if (left.isInfinite) return Rect.zero;
  return Rect.fromLTRB(left, top, right, bottom);
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  const options = WindowOptions(
    size: Size(1180, 760),
    minimumSize: Size(720, 480),
    center: true,
    backgroundColor: Colors.transparent,
    titleBarStyle: TitleBarStyle.hidden,
    skipTaskbar: false,
    alwaysOnTop: true,
  );
  await windowManager.waitUntilReadyToShow(options, () async {
    await windowManager.show();
    await windowManager.focus();
  });
  runApp(const PenApp());
}

enum CanvasMode { screen, whiteboard, blackboard }

enum ToolType { pen, highlighter, text, line, rectangle, candlestick }

enum ToolbarDock { left, right, top, bottom }

enum MagnifierZoom { x2, x4, x8 }

enum MagnifierSize { small, medium, large }

/// Thickness of the main toolbar strip (vertical width / horizontal height).
const double kToolbarThickness = 56;

/// Explicit Pointer tool (presentation ring). Distinct from idle desktop
/// (`activeSlotId == null`) which uses a normal OS cursor with no ring.
const String kPointerSlotId = '__pointer__';

const List<double> magnifierZoomFactors = <double>[2, 4, 8];

extension MagnifierZoomX on MagnifierZoom {
  double get factor => magnifierZoomFactors[index];

  String get label => '${factor.toStringAsFixed(0)}×';
}

extension MagnifierSizeX on MagnifierSize {
  /// Logical lens size before zoom (width × height).
  Size get lensSize => switch (this) {
    MagnifierSize.small => const Size(140, 100),
    MagnifierSize.medium => const Size(220, 150),
    MagnifierSize.large => const Size(320, 220),
  };

  String get label => switch (this) {
    MagnifierSize.small => 'S',
    MagnifierSize.medium => 'M',
    MagnifierSize.large => 'L',
  };
}

extension ToolbarDockX on ToolbarDock {
  bool get isVertical => this == ToolbarDock.left || this == ToolbarDock.right;

  String get label => switch (this) {
    ToolbarDock.left => 'Left',
    ToolbarDock.right => 'Right',
    ToolbarDock.top => 'Top',
    ToolbarDock.bottom => 'Bottom',
  };

  IconData get icon => switch (this) {
    ToolbarDock.left => Icons.align_horizontal_left,
    ToolbarDock.right => Icons.align_horizontal_right,
    ToolbarDock.top => Icons.align_vertical_top,
    ToolbarDock.bottom => Icons.align_vertical_bottom,
  };
}

extension CanvasModeLabel on CanvasMode {
  String get label => switch (this) {
    CanvasMode.screen => 'Screen',
    CanvasMode.whiteboard => 'Whiteboard',
    CanvasMode.blackboard => 'Blackboard',
  };

  IconData get icon => switch (this) {
    CanvasMode.screen => Icons.desktop_windows_outlined,
    CanvasMode.whiteboard => Icons.crop_landscape,
    CanvasMode.blackboard => Icons.crop_portrait,
  };
}

extension ToolTypeLabel on ToolType {
  String get label => switch (this) {
    ToolType.pen => 'Pen',
    ToolType.highlighter => 'Highlighter',
    ToolType.text => 'Text',
    ToolType.line => 'Line',
    ToolType.rectangle => 'Rectangle',
    ToolType.candlestick => 'Candle',
  };

  /// Material glyph for tools that use a stock icon. Highlighter and candle
  /// tools use a custom painter instead — see [_HighlighterIcon] /
  /// [_CandlestickIcon].
  IconData? get icon => switch (this) {
    ToolType.pen => Icons.edit_outlined,
    ToolType.highlighter => null,
    ToolType.text => Icons.title,
    ToolType.line => Icons.horizontal_rule,
    ToolType.rectangle => Icons.crop_square,
    ToolType.candlestick => null,
  };

  Widget get toolbarIcon => switch (this) {
    ToolType.highlighter => const _HighlighterIcon(),
    ToolType.candlestick => const _CandlestickIcon(),
    _ => Icon(icon, size: 20),
  };
}

const double highlighterOpacity = .32;
const List<double> toolWidthOptions = <double>[2, 4, 8, 14, 20];

const List<Color> annotationColors = <Color>[
  Color(0xffffffff),
  Color(0xffd7dde8),
  Color(0xff1d2433),
  Color(0xff000000),
  Color(0xffff4d67),
  Color(0xffff8a3d),
  Color(0xffffd447),
  Color(0xff9ee65f),
  Color(0xff46d17d),
  Color(0xff20c7b7),
  Color(0xff40c9ff),
  Color(0xff35a7ff),
  Color(0xff4f72ff),
  Color(0xff8a6cff),
  Color(0xffc66bff),
  Color(0xffff70b7),
];

class ToolSlot {
  ToolSlot({
    required this.id,
    required this.type,
    required this.color,
    required this.thickness,
    this.filled = false,
    this.fontSize = 24,
    this.presetText,
  });

  final String id;
  ToolType type;
  Color color;
  double thickness;
  bool filled;
  double fontSize;
  String? presetText;

  Color get drawingColor => type == ToolType.highlighter
      ? color.withValues(alpha: highlighterOpacity)
      : color.withValues(alpha: 1);

  String? get placedPresetText {
    final text = presetText?.trim();
    if (text == null || text.isEmpty) return null;
    return text;
  }

  String? get toolbarTitle {
    if (type == ToolType.candlestick) {
      if (id == kGreenCandleSlotId) return 'Green Candle';
      if (id == kRedCandleSlotId) return 'Red Candle';
    }
    return placedPresetText ?? type.label;
  }

  String? get toolbarBadge {
    if (placedPresetText != null) return placedPresetText![0].toUpperCase();
    if (type == ToolType.rectangle && filled) return 'F';
    return null;
  }

  ToolSlot copy() => ToolSlot(
    id: id,
    type: type,
    color: color,
    thickness: thickness,
    filled: filled,
    fontSize: fontSize,
    presetText: presetText,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'type': type.name,
    'color': color.toARGB32(),
    'thickness': thickness,
    'filled': filled,
    'fontSize': fontSize,
    'presetText': presetText,
  };

  factory ToolSlot.fromJson(Map<String, dynamic> json) {
    final thickness = (json['thickness'] as num).toDouble().clamp(1, 24);
    final fontSize = ((json['fontSize'] as num?)?.toDouble() ?? 24).clamp(
      12,
      72,
    );
    final presetRaw = json['presetText'] as String?;
    final presetText = presetRaw == null || presetRaw.trim().isEmpty
        ? null
        : presetRaw;
    return ToolSlot(
      id: json['id'] as String,
      type: ToolType.values.byName(json['type'] as String),
      color: Color(json['color'] as int).withValues(alpha: 1),
      thickness: thickness.toDouble(),
      filled: json['filled'] as bool? ?? false,
      fontSize: fontSize.toDouble(),
      presetText: presetText,
    );
  }
}

abstract class Drawable {
  const Drawable();
  Map<String, dynamic> toJson();
}

class StrokeDrawable extends Drawable {
  const StrokeDrawable(this.points, this.color, this.width);
  final List<Offset> points;
  final Color color;
  final double width;

  @override
  Map<String, dynamic> toJson() => {
    'kind': 'stroke',
    'points': points.map((p) => [p.dx, p.dy]).toList(),
    'color': color.toARGB32(),
    'width': width,
  };
}

class LineDrawable extends Drawable {
  const LineDrawable(this.start, this.end, this.color, this.width);
  final Offset start;
  final Offset end;
  final Color color;
  final double width;

  @override
  Map<String, dynamic> toJson() => {
    'kind': 'line',
    'start': [start.dx, start.dy],
    'end': [end.dx, end.dy],
    'color': color.toARGB32(),
    'width': width,
  };
}

class RectangleDrawable extends Drawable {
  const RectangleDrawable(this.rect, this.color, this.width, this.filled);
  final Rect rect;
  final Color color;
  final double width;
  final bool filled;

  @override
  Map<String, dynamic> toJson() => {
    'kind': 'rectangle',
    'rect': [rect.left, rect.top, rect.right, rect.bottom],
    'color': color.toARGB32(),
    'width': width,
    'filled': filled,
  };
}

class TextDrawable extends Drawable {
  const TextDrawable(this.position, this.text, this.color, this.fontSize);
  final Offset position;
  final String text;
  final Color color;
  final double fontSize;

  @override
  Map<String, dynamic> toJson() => {
    'kind': 'text',
    'position': [position.dx, position.dy],
    'text': text,
    'color': color.toARGB32(),
    'fontSize': fontSize,
  };
}

class CandleSpec {
  const CandleSpec({
    required this.x,
    required this.width,
    required this.openY,
    required this.closeY,
    required this.highY,
    required this.lowY,
  });

  final double x;
  final double width;
  final double openY;
  final double closeY;
  final double highY;
  final double lowY;

  bool get isBullish => closeY < openY;

  Map<String, dynamic> toJson() => {
    'x': x,
    'width': width,
    'openY': openY,
    'closeY': closeY,
    'highY': highY,
    'lowY': lowY,
  };

  factory CandleSpec.fromJson(Map<String, dynamic> json) => CandleSpec(
    x: (json['x'] as num).toDouble(),
    width: (json['width'] as num).toDouble(),
    openY: (json['openY'] as num).toDouble(),
    closeY: (json['closeY'] as num).toDouble(),
    highY: (json['highY'] as num).toDouble(),
    lowY: (json['lowY'] as num).toDouble(),
  );
}

class CandleGroupDrawable extends Drawable {
  const CandleGroupDrawable(
    this.candles, {
    required this.strokeWidth,
    this.bullColor = kCandleBullColor,
    this.bearColor = kCandleBearColor,
  });

  final List<CandleSpec> candles;
  final double strokeWidth;
  final Color bullColor;
  final Color bearColor;

  @override
  Map<String, dynamic> toJson() => {
    'kind': 'candles',
    'candles': candles.map((c) => c.toJson()).toList(),
    'width': strokeWidth,
    'bullColor': bullColor.toARGB32(),
    'bearColor': bearColor.toARGB32(),
  };
}

Drawable? drawableFromJson(Map<String, dynamic> json) {
  final kind = json['kind'] as String;
  if (kind == 'candles') {
    final raw = json['candles'] as List;
    return CandleGroupDrawable(
      raw
          .map((item) => CandleSpec.fromJson(item as Map<String, dynamic>))
          .toList(),
      strokeWidth: (json['width'] as num?)?.toDouble() ?? 2,
      bullColor: json['bullColor'] is int
          ? Color(json['bullColor'] as int)
          : kCandleBullColor,
      bearColor: json['bearColor'] is int
          ? Color(json['bearColor'] as int)
          : kCandleBearColor,
    );
  }
  final color = Color(json['color'] as int);
  switch (kind) {
    case 'stroke':
      return StrokeDrawable(
        (json['points'] as List)
            .map(
              (p) => Offset((p[0] as num).toDouble(), (p[1] as num).toDouble()),
            )
            .toList(),
        color,
        (json['width'] as num).toDouble(),
      );
    case 'line':
      final start = json['start'] as List;
      final end = json['end'] as List;
      return LineDrawable(
        Offset((start[0] as num).toDouble(), (start[1] as num).toDouble()),
        Offset((end[0] as num).toDouble(), (end[1] as num).toDouble()),
        color,
        (json['width'] as num).toDouble(),
      );
    case 'rectangle':
      final rect = json['rect'] as List;
      return RectangleDrawable(
        Rect.fromLTRB(
          (rect[0] as num).toDouble(),
          (rect[1] as num).toDouble(),
          (rect[2] as num).toDouble(),
          (rect[3] as num).toDouble(),
        ),
        color,
        (json['width'] as num).toDouble(),
        json['filled'] as bool,
      );
    case 'text':
      final position = json['position'] as List;
      return TextDrawable(
        Offset(
          (position[0] as num).toDouble(),
          (position[1] as num).toDouble(),
        ),
        json['text'] as String,
        color,
        (json['fontSize'] as num).toDouble(),
      );
    default:
      return null;
  }
}

/// Hand tool id. Like eraser/magnifier it is a mode, not a saved ToolSlot.
const String kHandSlotId = '__hand__';

/// How far (share of screen width/height) you must drag to change slide.
const double kSlidePanFraction = 0.4;

/// Empty space between two slide tiles on the endless board map.
const double kBoardSlideGap = 72;

/// Key you can hold to move the board while a drawing tool is still selected.
enum BoardPanKey { space, control, alt }

extension BoardPanKeyX on BoardPanKey {
  String get label => switch (this) {
    BoardPanKey.space => 'Space',
    BoardPanKey.control => 'Control',
    BoardPanKey.alt => 'Alt',
  };
}

/// True when the chosen move-key is currently held down.
bool isBoardPanKeyHeld(BoardPanKey key) {
  final keyboard = HardwareKeyboard.instance;
  return switch (key) {
    BoardPanKey.space => keyboard.logicalKeysPressed.contains(
      LogicalKeyboardKey.space,
    ),
    BoardPanKey.control => keyboard.isControlPressed,
    BoardPanKey.alt => keyboard.isAltPressed,
  };
}

/// Default slide name is just its number: 1, 2, 3...
String defaultSlideTitle(int index) => '${index + 1}';

String newBoardSlideId() =>
    'slide-${DateTime.now().microsecondsSinceEpoch}';

/// Which way a finished drag wants to go.
enum BoardSlideStep { previous, stay, next }

/// Drag left/up far enough -> next (the tile on the right / below slides in).
/// Drag right/down far enough -> previous. Otherwise stay.
/// The content follows the pointer, like pulling paper toward you.
BoardSlideStep slideStepForPan(
  Offset pan,
  Size viewport, {
  double fraction = kSlidePanFraction,
}) {
  if (viewport.width <= 0 || viewport.height <= 0) {
    return BoardSlideStep.stay;
  }
  final thresholdX = viewport.width * fraction;
  final thresholdY = viewport.height * fraction;
  if (pan.dx <= -thresholdX || pan.dy <= -thresholdY) {
    return BoardSlideStep.next;
  }
  if (pan.dx >= thresholdX || pan.dy >= thresholdY) {
    return BoardSlideStep.previous;
  }
  return BoardSlideStep.stay;
}

/// Top-left corner of a slide tile in endless board coordinates.
Offset boardSlideOrigin({
  required int col,
  required int row,
  required Size viewport,
  double gap = kBoardSlideGap,
}) {
  return Offset(col * (viewport.width + gap), row * (viewport.height + gap));
}

/// Which tile is closest to the middle of the screen for a free camera.
/// Lets the view stop between tiles instead of snapping every time.
({int col, int row}) boardCellForCamera(
  Offset camera,
  Size viewport, {
  double gap = kBoardSlideGap,
}) {
  if (viewport.width <= 0 || viewport.height <= 0) {
    return (col: 0, row: 0);
  }
  final boardCenter =
      Offset(viewport.width / 2, viewport.height / 2) - camera;
  final col =
      ((boardCenter.dx - viewport.width / 2) / (viewport.width + gap)).round();
  final row =
      ((boardCenter.dy - viewport.height / 2) / (viewport.height + gap))
          .round();
  return (col: col, row: row);
}

/// Camera that centers exactly on [slide] for the given screen size.
/// Tapping a slide number uses this; dragging leaves the camera free.
Offset cameraForSlide(BoardSlide slide, Size viewport) {
  return -boardSlideOrigin(col: slide.col, row: slide.row, viewport: viewport);
}

int indexOfBoardSlide(List<BoardSlide> slides, String? id) {
  if (id == null) return 0;
  final index = slides.indexWhere((slide) => slide.id == id);
  return index < 0 ? 0 : index;
}

/// One tile on the endless board map. Each slide keeps its own drawings
/// in its own local coordinates (0,0 is the slide's top-left).
/// [col] grows to the right, [row] grows downward. Negative values allow
/// endlesstiles to the left and above the start.
class BoardSlide {
  BoardSlide({
    required this.id,
    required this.title,
    List<Drawable>? drawables,
    this.col = 0,
    this.row = 0,
  }) : drawables = drawables ?? <Drawable>[];

  final String id;
  String title;
  final List<Drawable> drawables;
  int col;
  int row;

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'col': col,
    'row': row,
    'drawables': drawables.map((item) => item.toJson()).toList(),
  };

  factory BoardSlide.fromJson(Map<String, dynamic> json) {
    final drawables = <Drawable>[];
    final raw = json['drawables'] as List?;
    if (raw != null) {
      for (final item in raw) {
        try {
          final drawable = drawableFromJson(item as Map<String, dynamic>);
          if (drawable != null) drawables.add(drawable);
        } catch (_) {
          // Skip one bad drawing without losing the whole slide.
        }
      }
    }
    final rawTitle = json['title'] as String?;
    return BoardSlide(
      id: json['id'] as String,
      title: (rawTitle == null || rawTitle.trim().isEmpty)
          ? '1'
          : rawTitle.trim(),
      col: (json['col'] as num?)?.toInt() ?? 0,
      row: (json['row'] as num?)?.toInt() ?? 0,
      drawables: drawables,
    );
  }
}

/// Find the tile at a grid spot, or null when that spot is still empty.
BoardSlide? slideAt(List<BoardSlide> slides, int col, int row) {
  for (final slide in slides) {
    if (slide.col == col && slide.row == row) return slide;
  }
  return null;
}

class PenApp extends StatelessWidget {
  const PenApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'Screen pen by Hamed Mosaddeghian',
    theme: ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: Colors.transparent,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xff4db6ff),
        brightness: Brightness.dark,
      ),
      fontFamily: 'Segoe UI',
      tooltipTheme: const TooltipThemeData(
        waitDuration: Duration(milliseconds: 350),
      ),
    ),
    home: const AnnotationWorkspace(),
  );
}

class AnnotationWorkspace extends StatefulWidget {
  const AnnotationWorkspace({super.key});

  @override
  State<AnnotationWorkspace> createState() => _AnnotationWorkspaceState();
}

class _AnnotationWorkspaceState extends State<AnnotationWorkspace>
    with WindowListener {
  final _canvasKey = GlobalKey();
  final _keyboardFocus = FocusNode();
  final _canvas = <CanvasMode, List<Drawable>>{
    for (final mode in CanvasMode.values) mode: <Drawable>[],
  };
  final _undo = <CanvasMode, List<List<Drawable>>>{
    for (final mode in CanvasMode.values) mode: <List<Drawable>>[],
  };
  final _boardSlides = <CanvasMode, List<BoardSlide>>{
    CanvasMode.whiteboard: [
      BoardSlide(id: 'slide-whiteboard-1', title: '1', col: 0, row: 0),
    ],
    CanvasMode.blackboard: [
      BoardSlide(id: 'slide-blackboard-1', title: '1', col: 0, row: 0),
    ],
  };
  final _activeSlideId = <CanvasMode, String?>{
    CanvasMode.whiteboard: 'slide-whiteboard-1',
    CanvasMode.blackboard: 'slide-blackboard-1',
  };
  final _boardPan = <CanvasMode, Offset>{
    for (final mode in CanvasMode.values) mode: Offset.zero,
  };
  // True = snapped exactly onto the active slide (clipped view showing only
  // inside its borders). False = free roaming camera that may sit between
  // tiles and shows everything including gaps.
  final _boardFocused = <CanvasMode, bool>{
    for (final mode in CanvasMode.values) mode: true,
  };
  final _slideUndo = <String, List<List<Drawable>>>{};
  BoardPanKey _panKey = BoardPanKey.space;
  bool _isPanningBoard = false;

  final _quickColors = <Color>[
    const Color(0xff35a7ff),
    const Color(0xffffd447),
    const Color(0xff56d364),
    const Color(0xffff5d73),
    const Color(0xffffffff),
    const Color(0xff1d2433),
    const Color(0xff20c7b7),
    const Color(0xffc66bff),
  ];
  final _slots = <ToolSlot>[
    ToolSlot(
      id: 'pen-a',
      type: ToolType.pen,
      color: const Color(0xff35a7ff),
      thickness: 4,
    ),
    ToolSlot(
      id: 'highlighter-a',
      type: ToolType.highlighter,
      color: const Color(0xffffd447),
      thickness: 20,
    ),
    ToolSlot(
      id: 'text-a',
      type: ToolType.text,
      color: const Color(0xff35a7ff),
      thickness: 3,
      fontSize: 24,
    ),
    ToolSlot(
      id: 'text-important',
      type: ToolType.text,
      color: const Color(0xffff5d73),
      thickness: 3,
      fontSize: 28,
      presetText: 'Important',
    ),
    ToolSlot(
      id: 'text-note',
      type: ToolType.text,
      color: const Color(0xff35a7ff),
      thickness: 3,
      fontSize: 24,
      presetText: 'Note',
    ),
    ToolSlot(
      id: 'line-a',
      type: ToolType.line,
      color: const Color(0xffffd447),
      thickness: 4,
    ),
    ToolSlot(
      id: 'rect-a',
      type: ToolType.rectangle,
      color: const Color(0xff56d364),
      thickness: 4,
    ),
    ToolSlot(
      id: kGreenCandleSlotId,
      type: ToolType.candlestick,
      color: kCandleBullColor,
      thickness: 8,
    ),
    ToolSlot(
      id: kRedCandleSlotId,
      type: ToolType.candlestick,
      color: kCandleBearColor,
      thickness: 8,
    ),
  ];

  CanvasMode _mode = CanvasMode.screen;
  String? _activeSlotId = 'pen-a';
  String? _toolBeforeCollapse;
  ToolbarDock _toolbarDock = ToolbarDock.left;
  bool _sidebarOpen = true;
  bool _paletteOpen = false;
  bool _presentationCursor = false;
  bool _passThrough = false;
  bool _coverTaskbar = true;
  bool _rememberContent = true;
  bool _expandedColors = false;
  MagnifierZoom _magnifierZoom = MagnifierZoom.x2;
  MagnifierSize _magnifierSize = MagnifierSize.medium;
  String _screenshotFolder = '';
  List<Offset> _draftPoints = <Offset>[];
  Offset? _draftStart;
  Offset? _draftEnd;
  Offset? _pointerPosition;
  Offset? _textOrigin;
  bool _editingText = false;
  bool _isLoading = true;
  bool _pointerPollInFlight = false;
  bool _magnifierCaptureInFlight = false;
  bool _draggingToolbar = false;
  bool _eraserGestureChanged = false;
  final _eraserPushedSlides = <String>{};
  bool _shiftPressed = false;
  bool _shuttingDown = false;
  bool _hitTestSyncScheduled = false;
  CandleGroupDrawable? _pendingCandle;
  int _passThroughOverlayDepth = 0;
  ui.Image? _magnifierImage;
  final _toolbarKey = GlobalKey();
  final _restoreKey = GlobalKey();
  final _slideBarKey = GlobalKey();
  final _textController = TextEditingController();
  final _textFocus = FocusNode();
  Timer? _pointerTimer;
  Timer? _magnifierTimer;
  Timer? _saveTimer;
  Timer? _shiftPollTimer;
  Offset? _panStartLocal;
  Offset _panBase = Offset.zero;
  bool _middlePanArmed = false;

  bool get _isEraserSelected => _activeSlotId == '__eraser__';
  bool get _isMagnifierSelected => _activeSlotId == '__magnifier__';
  bool get _isPointerMode => _activeSlotId == kPointerSlotId;
  bool get _isHandSelected => _activeSlotId == kHandSlotId;
  bool get _isIdleDesktop => _activeSlotId == null;
  bool get _hasDrawingTool => _activeSlotId != null && !_isPointerMode;
  bool get _isBoardMode =>
      _mode == CanvasMode.whiteboard || _mode == CanvasMode.blackboard;
  List<BoardSlide> get _activeSlides {
    if (!_isBoardMode) return const <BoardSlide>[];
    return _boardSlides[_mode]!;
  }

  BoardSlide _ensureActiveSlide() {
    final slides = _boardSlides[_mode]!;
    if (slides.isEmpty) {
      final created = BoardSlide(
        id: newBoardSlideId(),
        title: defaultSlideTitle(0),
        col: 0,
        row: 0,
      );
      slides.add(created);
      _activeSlideId[_mode] = created.id;
      return created;
    }
    final id = _activeSlideId[_mode];
    for (final slide in slides) {
      if (slide.id == id) return slide;
    }
    _activeSlideId[_mode] = slides.first.id;
    return slides.first;
  }

  Offset get _activePan => _boardPan[_mode] ?? Offset.zero;

  bool get _isBoardFocused => _boardFocused[_mode] ?? true;

  Size get _viewportSize =>
      MediaQuery.maybeOf(context)?.size ?? const Size(1180, 760);

  /// Camera to use for painting. Focused = recomputed snap (safe on resize).
  /// Roaming = stored free camera that may sit between tiles.
  Offset _cameraForPaint() {
    if (!_isBoardMode) return Offset.zero;
    if (_isBoardFocused) {
      return cameraForSlide(_ensureActiveSlide(), _viewportSize);
    }
    return _activePan;
  }

  Offset _activeSlideOrigin() {
    final slide = _ensureActiveSlide();
    return boardSlideOrigin(
      col: slide.col,
      row: slide.row,
      viewport: _viewportSize,
    );
  }

  /// Screen touch -> drawing position inside the active slide.
  /// In focused view this is unchanged; between tiles it can be outside
  /// 0..viewport (overflow shown while roaming, hidden when focused).
  Offset _screenToActiveLocal(Offset screen) {
    if (!_isBoardMode) return screen;
    final camera = _isBoardFocused
        ? cameraForSlide(_ensureActiveSlide(), _viewportSize)
        : _activePan;
    return screen - camera - _activeSlideOrigin();
  }

  /// Desktop click-through when idle, pointer, or magnifier is active (toolbar
  /// still hit-tests), or when the toolbar is collapsed.
  bool get _wantPassThrough =>
      _passThroughOverlayDepth == 0 &&
      (!_sidebarOpen ||
          _isIdleDesktop ||
          _isPointerMode ||
          _isMagnifierSelected);
  ToolSlot? get _selectedSlot {
    final id = _activeSlotId;
    if (id == null ||
        id == '__eraser__' ||
        id == kPointerSlotId ||
        id == kHandSlotId ||
        id == '__magnifier__') {
      return null;
    }
    for (final slot in _slots) {
      if (slot.id == id) return slot;
    }
    return null;
  }

  ToolSlot get _activeSlot => _selectedSlot ?? _slots.first;
  List<Drawable> get _activeDrawables {
    if (_mode == CanvasMode.screen) return _canvas[_mode]!;
    return _ensureActiveSlide().drawables;
  }
  Offset? get _previewLineEnd =>
      _draftEnd == null ? null : _effectiveLineEnd(_draftEnd!);

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _nativeChannel.setMethodCallHandler(_handleNativeCall);
    unawaited(_initialize());
  }

  @override
  void dispose() {
    _pointerTimer?.cancel();
    _magnifierTimer?.cancel();
    _saveTimer?.cancel();
    _shiftPollTimer?.cancel();
    _magnifierImage?.dispose();
    _nativeChannel.setMethodCallHandler(null);
    windowManager.removeListener(this);
    _keyboardFocus.dispose();
    _textFocus.dispose();
    _textController.dispose();
    super.dispose();
  }

  Future<void> _initialize() async {
    unawaited(_configureWindowClose());
    final inFlutterTest = Platform.environment.containsKey('FLUTTER_TEST');
    if (Platform.isWindows && !inFlutterTest) {
      try {
        await windowManager.setAsFrameless();
        await windowManager.setHasShadow(false);
      } catch (_) {
        // Non-desktop hosts skip window chrome APIs.
      }
    }
    await _loadPreferences();
  }

  Future<void> _configureWindowClose() async {
    try {
      await windowManager.setPreventClose(true);
    } catch (_) {
      // Window APIs are unavailable in widget tests and on non-desktop hosts.
    }
  }

  Future<dynamic> _handleNativeCall(MethodCall call) async {
    if (call.method == 'togglePointerMode' && mounted) {
      await _togglePointerMode();
    }
  }

  @override
  void onWindowClose() {
    unawaited(_shutdown());
  }

  Future<void> _loadPreferences() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final rawSlots = prefs.getStringList('tool_slots');
      if (rawSlots != null && rawSlots.isNotEmpty) {
        final decodedSlots = <ToolSlot>[];
        final seenIds = <String>{};
        var legacyUnsupportedSlotsFound = false;
        for (final value in rawSlots) {
          try {
            final json = jsonDecode(value) as Map<String, dynamic>;
            final rawType = json['type'];
            if (rawType is! String ||
                !ToolType.values.any((type) => type.name == rawType)) {
              legacyUnsupportedSlotsFound = true;
              continue;
            }
            final slot = ToolSlot.fromJson(json);
            if (slot.id.isNotEmpty && seenIds.add(slot.id)) {
              decodedSlots.add(slot);
            }
          } catch (_) {
            // Keep loading valid tools if one saved entry is corrupt.
          }
        }
        if (decodedSlots.isNotEmpty || legacyUnsupportedSlotsFound) {
          String availableId(String base) {
            var candidate = base;
            var suffix = 2;
            while (decodedSlots.any((slot) => slot.id == candidate)) {
              candidate = '$base-${suffix++}';
            }
            return candidate;
          }

          final slotsMigratedV2 = prefs.getBool('slots_migrated_v2') ?? false;
          var slotsMigrationApplied = false;
          if (!slotsMigratedV2) {
            final penCount = decodedSlots
                .where((slot) => slot.type == ToolType.pen)
                .length;
            final hasHighlighter = decodedSlots.any(
              (slot) => slot.type == ToolType.highlighter,
            );
            if (penCount >= 2 && !hasHighlighter) {
              final firstPenIndex = decodedSlots.indexWhere(
                (slot) => slot.type == ToolType.pen,
              );
              final secondPenIndex = decodedSlots.indexWhere(
                (slot) => slot.type == ToolType.pen,
                firstPenIndex + 1,
              );
              if (secondPenIndex >= 0) {
                final secondPen = decodedSlots[secondPenIndex];
                final highlighterId = secondPen.id == 'pen-b'
                    ? availableId('highlighter-a')
                    : secondPen.id;
                decodedSlots[secondPenIndex] = ToolSlot(
                  id: highlighterId,
                  type: ToolType.highlighter,
                  color: const Color(0xffffd447),
                  thickness: 20,
                );
                slotsMigrationApplied = true;
              }
            }
            await prefs.setBool('slots_migrated_v2', true);
            if (slotsMigrationApplied) {
              await prefs.setStringList(
                'tool_slots',
                decodedSlots.map((slot) => jsonEncode(slot.toJson())).toList(),
              );
            }
          }

          final slotsMigratedV3 = prefs.getBool('slots_migrated_v3') ?? false;
          if (!slotsMigratedV3) {
            final textIndex = decodedSlots.indexWhere(
              (slot) => slot.type == ToolType.text,
            );
            final highlighterIndex = decodedSlots.indexWhere(
              (slot) => slot.type == ToolType.highlighter,
            );
            final insertAt = textIndex >= 0
                ? textIndex + 1
                : highlighterIndex >= 0
                ? highlighterIndex + 1
                : decodedSlots.length;
            decodedSlots.insert(
              insertAt,
              ToolSlot(
                id: availableId('text-important'),
                type: ToolType.text,
                color: const Color(0xffff5d73),
                thickness: 3,
                fontSize: 28,
                presetText: 'Important',
              ),
            );
            decodedSlots.insert(
              insertAt + 1,
              ToolSlot(
                id: availableId('text-note'),
                type: ToolType.text,
                color: const Color(0xff35a7ff),
                thickness: 3,
                fontSize: 24,
                presetText: 'Note',
              ),
            );
            await prefs.setBool('slots_migrated_v3', true);
            await prefs.setStringList(
              'tool_slots',
              decodedSlots.map((slot) => jsonEncode(slot.toJson())).toList(),
            );
          }

          final slotsMigratedV5 = prefs.getBool('slots_migrated_v5') ?? false;
          if (!slotsMigratedV5 || legacyUnsupportedSlotsFound) {
            var candleSlotsMigrationApplied = legacyUnsupportedSlotsFound;

            int candleInsertIndex() {
              final candleIndex = decodedSlots.lastIndexWhere(
                (slot) => slot.type == ToolType.candlestick,
              );
              if (candleIndex >= 0) return candleIndex + 1;
              final rectIndex = decodedSlots.lastIndexWhere(
                (slot) => slot.type == ToolType.rectangle,
              );
              return rectIndex >= 0 ? rectIndex + 1 : decodedSlots.length;
            }

            final greenCandleIndex = decodedSlots.indexWhere(
              (slot) =>
                  slot.id == kGreenCandleSlotId &&
                  slot.type == ToolType.candlestick,
            );
            if (greenCandleIndex < 0) {
              final legacyCandleIndex = decodedSlots.indexWhere(
                (slot) =>
                    slot.id == 'candle-draw' &&
                    slot.type == ToolType.candlestick,
              );
              if (legacyCandleIndex >= 0) {
                final legacyCandle = decodedSlots[legacyCandleIndex];
                decodedSlots[legacyCandleIndex] = ToolSlot(
                  id: availableId(kGreenCandleSlotId),
                  type: ToolType.candlestick,
                  color: legacyCandle.color,
                  thickness: legacyCandle.thickness,
                  filled: legacyCandle.filled,
                  fontSize: legacyCandle.fontSize,
                  presetText: legacyCandle.presetText,
                );
              } else {
                decodedSlots.insert(
                  candleInsertIndex(),
                  ToolSlot(
                    id: availableId(kGreenCandleSlotId),
                    type: ToolType.candlestick,
                    color: kCandleBullColor,
                    thickness: 8,
                  ),
                );
              }
              candleSlotsMigrationApplied = true;
            }

            if (!decodedSlots.any(
              (slot) =>
                  slot.id == kRedCandleSlotId &&
                  slot.type == ToolType.candlestick,
            )) {
              decodedSlots.insert(
                candleInsertIndex(),
                ToolSlot(
                  id: availableId(kRedCandleSlotId),
                  type: ToolType.candlestick,
                  color: kCandleBearColor,
                  thickness: 8,
                ),
              );
              candleSlotsMigrationApplied = true;
            }

            await prefs.setBool('slots_migrated_v5', true);
            if (candleSlotsMigrationApplied || !slotsMigratedV5) {
              await prefs.setStringList(
                'tool_slots',
                decodedSlots.map((slot) => jsonEncode(slot.toJson())).toList(),
              );
            }
          }

          if (!decodedSlots.any((slot) => slot.type == ToolType.pen)) {
            decodedSlots.insert(
              0,
              ToolSlot(
                id: availableId('pen-a'),
                type: ToolType.pen,
                color: const Color(0xff35a7ff),
                thickness: 4,
              ),
            );
          }
          if (!decodedSlots.any((slot) => slot.type == ToolType.highlighter)) {
            final penIndex = decodedSlots.indexWhere(
              (slot) => slot.type == ToolType.pen,
            );
            decodedSlots.insert(
              penIndex < 0 ? 0 : penIndex + 1,
              ToolSlot(
                id: availableId('highlighter-a'),
                type: ToolType.highlighter,
                color: const Color(0xffffd447),
                thickness: 20,
              ),
            );
          }
          _slots
            ..clear()
            ..addAll(decodedSlots);
        }
      }

      final rawCanvas = prefs.getString('canvas_data');
      final legacyBoardDrawings = <CanvasMode, List<Drawable>>{
        CanvasMode.whiteboard: <Drawable>[],
        CanvasMode.blackboard: <Drawable>[],
      };
      if (rawCanvas != null) {
        final decoded = jsonDecode(rawCanvas) as Map<String, dynamic>;
        for (final mode in CanvasMode.values) {
          final list = decoded[mode.name] as List?;
          if (list == null) continue;
          for (final item in list) {
            try {
              final drawable = drawableFromJson(item as Map<String, dynamic>);
              if (drawable != null) {
                _canvas[mode]!.add(drawable);
                if (mode != CanvasMode.screen) {
                  legacyBoardDrawings[mode]!.add(drawable);
                }
              }
            } catch (_) {
              // Ignore a malformed object without discarding the full canvas.
            }
          }
        }
      }
      // Endless boards: each whiteboard/blackboard mode keeps its own slides.
      var loadedSlides = false;
      final rawSlides = prefs.getString('board_slides');
      if (rawSlides != null) {
        try {
          final decoded = jsonDecode(rawSlides) as Map<String, dynamic>;
          for (final mode in [CanvasMode.whiteboard, CanvasMode.blackboard]) {
            final list = decoded[mode.name] as List?;
            if (list == null) continue;
            final slides = <BoardSlide>[];
            for (final item in list) {
              try {
                slides.add(
                  BoardSlide.fromJson(item as Map<String, dynamic>),
                );
              } catch (_) {
                // Skip one bad slide without losing the whole board.
              }
            }
            if (slides.isNotEmpty) {
              _boardSlides[mode] = slides;
              loadedSlides = true;
            }
          }
        } catch (_) {
          // Fall back to legacy single-list boards below.
        }
      }
      if (!loadedSlides) {
        // First run after the endless-board update: keep old drawings
        // on Slide 1 so nothing is lost.
        for (final mode in [CanvasMode.whiteboard, CanvasMode.blackboard]) {
          final old = legacyBoardDrawings[mode]!;
          if (old.isNotEmpty) {
            final first = _boardSlides[mode]!.first;
            first.drawables
              ..clear()
              ..addAll(old);
          }
        }
      }
      final rawActiveSlides = prefs.getString('board_active_slide');
      if (rawActiveSlides != null) {
        try {
          final decoded = jsonDecode(rawActiveSlides) as Map<String, dynamic>;
          for (final mode in [CanvasMode.whiteboard, CanvasMode.blackboard]) {
            final id = decoded[mode.name] as String?;
            if (id != null &&
                _boardSlides[mode]!.any((slide) => slide.id == id)) {
              _activeSlideId[mode] = id;
            } else {
              _activeSlideId[mode] = _boardSlides[mode]!.first.id;
            }
          }
        } catch (_) {
          // Keep default Slide 1 if the saved slide is bad.
        }
      }
      // Fix slide titles that are still blank after an old save.
      for (final mode in [CanvasMode.whiteboard, CanvasMode.blackboard]) {
        final slides = _boardSlides[mode]!;
        for (var i = 0; i < slides.length; i++) {
          if (slides[i].title.trim().isEmpty) {
            slides[i].title = defaultSlideTitle(i);
          }
        }
        // Old saves had no grid spots: every slide loaded at 0,0 and would
        // overlap. Spread them into row 0 so each tile stays visible.
        final seen = <String>{};
        var needsSpread = false;
        for (final slide in slides) {
          final key = '${slide.col},${slide.row}';
          if (!seen.add(key)) {
            needsSpread = true;
            break;
          }
        }
        if (needsSpread) {
          for (var i = 0; i < slides.length; i++) {
            slides[i].col = i;
            slides[i].row = 0;
          }
        }
        // Always restart focused on the saved active tile (clipped view).
        _boardFocused[mode] = true;
        _boardPan[mode] = Offset.zero;
      }
      final panName = prefs.getString('board_pan_key');
      if (panName != null) {
        for (final key in BoardPanKey.values) {
          if (key.name == panName) {
            _panKey = key;
            break;
          }
        }
      }

      final savedSlot = prefs.getString('active_slot');
      if (savedSlot == '__none__') {
        _activeSlotId = null;
      } else if (savedSlot == kPointerSlotId ||
          savedSlot == kHandSlotId ||
          savedSlot == '__eraser__' ||
          savedSlot == '__magnifier__' ||
          (savedSlot != null && _slots.any((slot) => slot.id == savedSlot))) {
        _activeSlotId = savedSlot;
      } else {
        _activeSlotId = _slots.first.id;
      }
      final dockName = prefs.getString('toolbar_dock');
      if (dockName != null) {
        for (final dock in ToolbarDock.values) {
          if (dock.name == dockName) {
            _toolbarDock = dock;
            break;
          }
        }
      }
      _coverTaskbar = prefs.getBool('cover_taskbar') ?? true;
      _presentationCursor =
          prefs.getBool('presentation_cursor') ??
          prefs.getBool('clear_mouse') ??
          false;
      _rememberContent = prefs.getBool('remember_content') ?? true;
      _expandedColors = prefs.getBool('expanded_colors') ?? false;
      final zoomName = prefs.getString('magnifier_zoom');
      if (zoomName != null) {
        for (final zoom in MagnifierZoom.values) {
          if (zoom.name == zoomName) {
            _magnifierZoom = zoom;
            break;
          }
        }
      }
      final sizeName = prefs.getString('magnifier_size');
      if (sizeName != null) {
        for (final size in MagnifierSize.values) {
          if (size.name == sizeName) {
            _magnifierSize = size;
            break;
          }
        }
      }
      _screenshotFolder =
          prefs.getString('screenshot_folder') ?? _defaultScreenshotFolder;

      // Defaults already include Important / Note. Mark v3 done if this launch
      // did not migrate saved slots, so the next launch does not insert again.
      if (!(prefs.getBool('slots_migrated_v3') ?? false)) {
        await prefs.setBool('slots_migrated_v3', true);
      }
      if (!(prefs.getBool('slots_migrated_v5') ?? false)) {
        await prefs.setBool('slots_migrated_v5', true);
      }
    } catch (_) {
      // Invalid preferences must never leave the transparent app unusable.
      _activeSlotId = _slots.first.id;
      _screenshotFolder = _defaultScreenshotFolder;
    }
    if (!mounted) return;
    setState(() => _isLoading = false);
    await _fitOverlayToCurrentDisplay();
    await _syncPassThrough();
    _scheduleHitTestSync();
  }

  /// Fits the overlay to one physical monitor without mixing coordinate spaces
  /// from displays that use different DPI scales.
  Future<void> _fitOverlayToCurrentDisplay({
    bool useCursorDisplay = false,
  }) async {
    if (!Platform.isWindows) return;
    final coverTaskbar = _coverTaskbar || _mode != CanvasMode.screen;
    try {
      final fitted = await _nativeChannel.invokeMethod<bool>('fitOverlay', {
        'useCursorDisplay': useCursorDisplay,
        'coverTaskbar': coverTaskbar,
      });
      if (fitted == true) {
        await windowManager.setAlwaysOnTop(true);
        _scheduleHitTestSync();
        return;
      }
    } catch (_) {
      // Fall back to plugin APIs when the native runner is not present.
    }
    try {
      final position = await windowManager.getPosition();
      final size = await windowManager.getSize();
      final center = useCursorDisplay
          ? await screenRetriever.getCursorScreenPoint()
          : Offset(position.dx + size.width / 2, position.dy + size.height / 2);
      final displays = await screenRetriever.getAllDisplays();
      if (displays.isEmpty) return;
      final display = displays.firstWhere((candidate) {
        final origin = candidate.visiblePosition ?? Offset.zero;
        final displaySize = candidate.visibleSize ?? candidate.size;
        return Rect.fromLTWH(
          origin.dx,
          origin.dy,
          displaySize.width,
          displaySize.height,
        ).contains(center);
      }, orElse: () => displays.first);
      final workOrigin = display.visiblePosition ?? Offset.zero;
      final workSize = display.visibleSize ?? display.size;
      await windowManager.setFullScreen(false);
      await windowManager.setBounds(
        overlayBoundsForDisplay(
          workOrigin: workOrigin,
          workSize: workSize,
          displaySize: display.size,
          coverTaskbar: coverTaskbar,
        ),
      );
      await windowManager.setAlwaysOnTop(true);
      _scheduleHitTestSync();
    } catch (_) {
      // Some Linux/mobile test environments do not expose desktop display APIs.
    }
  }

  Future<void> _dragToolbar() async {
    if (_draggingToolbar || !Platform.isWindows) return;
    _draggingToolbar = true;
    await _suspendPassThroughForOverlay();
    try {
      await windowManager.setFullScreen(false);
      await windowManager.startDragging();
      await _fitOverlayToCurrentDisplay(useCursorDisplay: true);
    } catch (_) {
      // Losing a drag must not affect drawing or toolbar interaction.
    } finally {
      _draggingToolbar = false;
      await _resumePassThroughAfterOverlay();
      _scheduleHitTestSync();
    }
  }

  Future<void> _suspendPassThroughForOverlay() async {
    _passThroughOverlayDepth++;
    if (_passThroughOverlayDepth == 1) {
      await _syncPassThrough();
    }
  }

  Future<void> _resumePassThroughAfterOverlay() async {
    if (_passThroughOverlayDepth == 0) return;
    _passThroughOverlayDepth--;
    if (_passThroughOverlayDepth == 0) {
      await _syncPassThrough();
    }
  }

  Future<void> _togglePointerMode() async {
    if (_isPointerMode) {
      final restore = _toolBeforeCollapse ?? _slots.first.id;
      await _setActiveSlot(restore);
    } else {
      await _setActiveSlot(kPointerSlotId);
    }
  }

  Future<void> _setActiveSlot(String? id) async {
    if (_editingText) _commitInlineText();
    _commitPendingCandle();
    final leavingMagnifier = _isMagnifierSelected && id != '__magnifier__';
    setState(() {
      _activeSlotId = id;
      _paletteOpen = false;
      _isPanningBoard = false;
      if (id != null &&
          id != '__magnifier__' &&
          id != kPointerSlotId &&
          id != kHandSlotId &&
          id != '__eraser__') {
        _toolBeforeCollapse = id;
      }
      if (leavingMagnifier) {
        _magnifierImage?.dispose();
        _magnifierImage = null;
      }
    });
    _scheduleSave();
    await _syncPassThrough();
    _scheduleHitTestSync();
    if (id != null && id != kPointerSlotId && !_editingText) {
      _keyboardFocus.requestFocus();
    }
    if (id == '__magnifier__') {
      _startMagnifierCapture();
    } else {
      _magnifierTimer?.cancel();
      _magnifierTimer = null;
    }
  }

  Future<void> _syncPassThrough() async {
    if (_shuttingDown ||
        !Platform.isWindows ||
        Platform.environment.containsKey('FLUTTER_TEST')) {
      _passThrough = _wantPassThrough;
      return;
    }
    final enabled = _wantPassThrough;
    try {
      await _nativeChannel.invokeMethod<bool>('setPassThrough', {
        'enabled': enabled,
      });
      if (!enabled) {
        try {
          await windowManager.setIgnoreMouseEvents(false);
        } catch (_) {}
      }
    } catch (_) {
      try {
        await windowManager.setIgnoreMouseEvents(enabled, forward: true);
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() {
      _passThrough = enabled;
      // Clear hover-only cursor when leaving pass-through unless presentation
      // cursor is tracking during draw.
      if (!enabled && !_presentationCursor) _pointerPosition = null;
    });
    if (enabled || _presentationCursor || _isPointerMode) {
      _startPointerPolling();
    } else {
      _pointerTimer?.cancel();
      _pointerTimer = null;
      try {
        await windowManager.focus();
      } catch (_) {}
    }
    _scheduleHitTestSync();
  }

  void _scheduleHitTestSync() {
    if (_hitTestSyncScheduled || !Platform.isWindows) return;
    _hitTestSyncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _hitTestSyncScheduled = false;
      unawaited(_syncHitTestRects());
    });
  }

  Map<String, int>? _hitTestRectForKey(GlobalKey key, double dpr) {
    final box = key.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    if (box.size.width <= 0 || box.size.height <= 0) return null;
    final origin = box.localToGlobal(Offset.zero);
    final size = box.size;
    return <String, int>{
      'left': (origin.dx * dpr).round(),
      'top': (origin.dy * dpr).round(),
      'right': ((origin.dx + size.width) * dpr).round(),
      'bottom': ((origin.dy + size.height) * dpr).round(),
    };
  }

  Future<void> _syncHitTestRects() async {
    if (!Platform.isWindows || _shuttingDown || !mounted) return;
    if (!_wantPassThrough) {
      try {
        await _nativeChannel.invokeMethod<bool>('setHitTestRects', {
          'rects': <Map<String, int>>[],
        });
      } catch (_) {}
      return;
    }
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final rects = <Map<String, int>>[];
    final toolbarRect = _hitTestRectForKey(
      _sidebarOpen ? _toolbarKey : _restoreKey,
      dpr,
    );
    if (toolbarRect != null) rects.add(toolbarRect);
    // Bottom slide bar must stay clickable in board modes. Without this,
    // clicks on previous/next fall through to the Windows taskbar below.
    if (_isBoardMode) {
      final slideRect = _hitTestRectForKey(_slideBarKey, dpr);
      if (slideRect != null) rects.add(slideRect);
    }
    if (rects.isEmpty) return;
    try {
      await _nativeChannel.invokeMethod<bool>('setHitTestRects', {
        'rects': rects,
      });
    } catch (_) {}
  }

  void _startPointerPolling() {
    _pointerTimer?.cancel();
    unawaited(_pollPointerPosition());
    _pointerTimer = Timer.periodic(
      const Duration(milliseconds: 33),
      (_) => unawaited(_pollPointerPosition()),
    );
  }

  Future<void> _pollPointerPosition() async {
    if (_pointerPollInFlight || !mounted) return;
    final trackPointerRing =
        _isPointerMode || (_presentationCursor && _passThrough);
    final trackMagnifier = _isMagnifierSelected;
    if (!trackPointerRing && !trackMagnifier && !_presentationCursor) return;
    if (!_passThrough && !trackMagnifier && !_presentationCursor) return;
    _pointerPollInFlight = true;
    try {
      final values = await Future.wait<Offset>([
        screenRetriever.getCursorScreenPoint(),
        windowManager.getPosition(),
      ]);
      if (!mounted) return;
      final localPosition = values[0] - values[1];
      if (_pointerPosition != localPosition) {
        setState(() => _pointerPosition = localPosition);
      }
    } catch (_) {
      // Cursor polling is best-effort; the global hotkey remains available.
    } finally {
      _pointerPollInFlight = false;
    }
  }

  void _startMagnifierCapture() {
    _magnifierTimer?.cancel();
    unawaited(_captureMagnifierFrame());
    _magnifierTimer = Timer.periodic(
      const Duration(milliseconds: 90),
      (_) => unawaited(_captureMagnifierFrame()),
    );
  }

  Future<void> _captureMagnifierFrame() async {
    if (_magnifierCaptureInFlight || !_isMagnifierSelected || !mounted) return;
    if (!Platform.isWindows) return;
    _magnifierCaptureInFlight = true;
    try {
      final dpr = MediaQuery.devicePixelRatioOf(context);
      final lens = _magnifierSize.lensSize;
      final zoom = _magnifierZoom.factor;
      // Source crop in logical px, converted to physical for BitBlt.
      final srcW = (lens.width / zoom).round().clamp(8, 800);
      final srcH = (lens.height / zoom).round().clamp(8, 800);
      final width = (srcW * dpr).round().clamp(8, 8192);
      final height = (srcH * dpr).round().clamp(8, 8192);
      // Native path centers on the real OS cursor (physical GetCursorPos),
      // avoiding DPI / window-origin mismatches from Dart reconstruction.
      final raw = await _nativeChannel.invokeMethod<dynamic>(
        'captureScreenRect',
        <String, Object>{
          'width': width,
          'height': height,
          'centerOnCursor': true,
        },
      );
      if (!mounted || !_isMagnifierSelected || raw is! Map) return;
      final map = Map<Object?, Object?>.from(raw);
      if (map['ok'] != true) return;
      final bytes = map['bytes'];
      final w = map['width'];
      final h = map['height'];
      if (bytes is! List || w is! int || h is! int) return;
      final pixelBytes = Uint8List.fromList(bytes.cast<int>());
      final completer = Completer<ui.Image>();
      ui.decodeImageFromPixels(
        pixelBytes,
        w,
        h,
        ui.PixelFormat.rgba8888,
        completer.complete,
      );
      final image = await completer.future;
      if (!mounted || !_isMagnifierSelected) {
        image.dispose();
        return;
      }
      setState(() {
        _magnifierImage?.dispose();
        _magnifierImage = image;
      });
    } catch (_) {
      // Magnifier capture is best-effort across DPI / multi-monitor edges.
    } finally {
      _magnifierCaptureInFlight = false;
    }
  }

  String get _defaultScreenshotFolder {
    final home = Platform.environment['USERPROFILE'] ?? Directory.current.path;
    return '$home${Platform.pathSeparator}Pictures${Platform.pathSeparator}Screen pen by Hamed Mosaddeghian';
  }

  Future<void> _savePreferences() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      'tool_slots',
      _slots.map((slot) => jsonEncode(slot.toJson())).toList(),
    );
    await prefs.setString('active_slot', _activeSlotId ?? '__none__');
    await prefs.setString('toolbar_dock', _toolbarDock.name);
    await prefs.setBool('cover_taskbar', _coverTaskbar);
    await prefs.setBool('presentation_cursor', _presentationCursor);
    await prefs.remove('clear_mouse');
    await prefs.setBool('remember_content', _rememberContent);
    await prefs.setBool('expanded_colors', _expandedColors);
    await prefs.setString('magnifier_zoom', _magnifierZoom.name);
    await prefs.setString('magnifier_size', _magnifierSize.name);
    await prefs.setString('screenshot_folder', _screenshotFolder);
    await prefs.setString('board_pan_key', _panKey.name);
    if (_rememberContent) {
      // Screen mode still uses the old single list. Boards use slides.
      final screenDrawings = _canvas[CanvasMode.screen]!
          .map((item) => item.toJson())
          .toList();
      await prefs.setString(
        'canvas_data',
        jsonEncode({
          CanvasMode.screen.name: screenDrawings,
          // Keep board drawings here too for very old backups.
          for (final mode in [CanvasMode.whiteboard, CanvasMode.blackboard])
            mode.name: _boardSlides[mode]!.isNotEmpty
                ? _boardSlides[mode]!.first.drawables
                      .map((item) => item.toJson())
                      .toList()
                : <Map<String, dynamic>>[],
        }),
      );
      await prefs.setString(
        'board_slides',
        jsonEncode({
          for (final mode in [CanvasMode.whiteboard, CanvasMode.blackboard])
            mode.name: _boardSlides[mode]!
                .map((slide) => slide.toJson())
                .toList(),
        }),
      );
      await prefs.setString(
        'board_active_slide',
        jsonEncode({
          for (final mode in [CanvasMode.whiteboard, CanvasMode.blackboard])
            mode.name: _activeSlideId[mode],
        }),
      );
    } else {
      await prefs.remove('canvas_data');
      await prefs.remove('board_slides');
      await prefs.remove('board_active_slide');
    }
  }

  void _scheduleSave() {
    if (_isLoading || _shuttingDown) return;
    _saveTimer?.cancel();
    _saveTimer = Timer(
      const Duration(milliseconds: 200),
      () => unawaited(_savePreferencesSafely()),
    );
  }

  Future<void> _savePreferencesSafely() async {
    try {
      await _savePreferences();
    } catch (_) {
      // Drawing must continue even if the preference store is unavailable.
    }
  }

  Future<void> _shutdown() async {
    if (_shuttingDown) return;
    _shuttingDown = true;
    _pointerTimer?.cancel();
    _magnifierTimer?.cancel();
    _saveTimer?.cancel();
    _shiftPollTimer?.cancel();
    _magnifierImage?.dispose();
    _magnifierImage = null;
    try {
      await _nativeChannel.invokeMethod<bool>('setPointerMode', {
        'enabled': false,
      });
    } catch (_) {
      try {
        await windowManager.setIgnoreMouseEvents(false);
      } catch (_) {
        // Continue shutdown even if the native window has already closed.
      }
    }
    await _savePreferencesSafely();
    try {
      await windowManager.setPreventClose(false);
      await windowManager.close();
    } catch (_) {
      try {
        await windowManager.destroy();
      } catch (_) {
        _shuttingDown = false;
      }
    }
  }

  String get _activeUndoKey {
    if (_mode == CanvasMode.screen) return 'screen';
    return _ensureActiveSlide().id;
  }

  List<List<Drawable>> _undoStackForActive() {
    if (_mode == CanvasMode.screen) return _undo[_mode]!;
    return _slideUndo.putIfAbsent(_activeUndoKey, () => <List<Drawable>>[]);
  }

  void _pushUndo() {
    final stack = _undoStackForActive();
    stack.add(List<Drawable>.from(_activeDrawables));
    if (stack.length > 50) stack.removeAt(0);
  }

  void _pushUndoFor(BoardSlide slide) {
    final stack = _slideUndo.putIfAbsent(slide.id, () => <List<Drawable>>[]);
    stack.add(List<Drawable>.from(slide.drawables));
    if (stack.length > 50) stack.removeAt(0);
  }

  void _undoLast() {
    final stack = _undoStackForActive();
    if (stack.isEmpty) return;
    final previous = stack.removeLast();
    setState(() {
      if (_mode == CanvasMode.screen) {
        _canvas[_mode] = previous;
      } else {
        final slide = _ensureActiveSlide();
        slide.drawables
          ..clear()
          ..addAll(previous);
      }
    });
    _scheduleSave();
  }

  void _clearCanvas() {
    if (_activeDrawables.isEmpty) return;
    _pushUndo();
    setState(() => _activeDrawables.clear());
    _scheduleSave();
  }

  void _selectMode(CanvasMode mode) {
    if (_mode == mode) return;
    if (_editingText) _commitInlineText();
    _commitPendingCandle();
    setState(() {
      _mode = mode;
      _paletteOpen = false;
      _isPanningBoard = false;
      if (mode != CanvasMode.screen) {
        _ensureActiveSlide();
        _boardFocused[mode] = true;
        // Snap after the new size is known; paint uses recomputed snap.
        _boardPan[mode] = Offset.zero;
      }
    });
    unawaited(_fitOverlayToCurrentDisplay());
    _scheduleSave();
    _scheduleHitTestSync();
  }

  void _selectHand() {
    unawaited(
      _setActiveSlot(_activeSlotId == kHandSlotId ? null : kHandSlotId),
    );
  }

  bool get _panKeyHeldNow {
    try {
      return isBoardPanKeyHeld(_panKey);
    } catch (_) {
      return false;
    }
  }

  List<BoardSlide> _slidesFor(CanvasMode mode) {
    if (mode == CanvasMode.screen) return const <BoardSlide>[];
    final slides = _boardSlides[mode]!;
    if (slides.isEmpty) {
      final created = BoardSlide(
        id: newBoardSlideId(),
        title: '1',
        col: 0,
        row: 0,
      );
      slides.add(created);
      _activeSlideId[mode] = created.id;
    }
    return slides;
  }

  BoardSlide _ensureSlideAt(int col, int row) {
    final slides = _slidesFor(_mode);
    final existing = slideAt(slides, col, row);
    if (existing != null) return existing;
    final created = BoardSlide(
      id: newBoardSlideId(),
      title: defaultSlideTitle(slides.length),
      col: col,
      row: row,
    );
    slides.add(created);
    return created;
  }

  void _selectSlide(String id) {
    if (!_isBoardMode) return;
    if (_editingText) _commitInlineText();
    _commitPendingCandle();
    setState(() {
      _activeSlideId[_mode] = id;
      _boardFocused[_mode] = true;
      _boardPan[_mode] = cameraForSlide(_ensureActiveSlide(), _viewportSize);
      _isPanningBoard = false;
      _draftStart = null;
      _draftEnd = null;
      _draftPoints = <Offset>[];
    });
    _scheduleSave();
    _scheduleHitTestSync();
  }

  void _addSlide() {
    if (!_isBoardMode) return;
    if (_editingText) _commitInlineText();
    _commitPendingCandle();
    final slides = _slidesFor(_mode);
    final active = _ensureActiveSlide();
    // New slide goes to the first empty tile to the right of the active one.
    var col = active.col + 1;
    while (slideAt(slides, col, active.row) != null) {
      col++;
    }
    final created = BoardSlide(
      id: newBoardSlideId(),
      title: defaultSlideTitle(slides.length),
      col: col,
      row: active.row,
    );
    setState(() {
      slides.add(created);
      _activeSlideId[_mode] = created.id;
      _boardFocused[_mode] = true;
      _boardPan[_mode] = cameraForSlide(created, _viewportSize);
    });
    _scheduleSave();
    _scheduleHitTestSync();
  }

  /// Move on the tile map. Endless in all four directions: missing tiles
  /// are created so you can keep going right, left, up, or down.
  void _stepSlideBy(int dCol, int dRow) {
    if (!_isBoardMode) return;
    final active = _ensureActiveSlide();
    final target = _ensureSlideAt(active.col + dCol, active.row + dRow);
    _selectSlide(target.id);
  }

  void _commitBoardPan() {
    if (!_isBoardMode) {
      _isPanningBoard = false;
      return;
    }
    // Free camera: stay exactly where the drag left the view so you can sit
    // between tiles. Only update which tile is active (nearest to center),
    // creating it when the map is still empty there.
    final size = _viewportSize;
    final cell = boardCellForCamera(_activePan, size);
    final target = _ensureSlideAt(cell.col, cell.row);
    _isPanningBoard = false;
    setState(() {
      _activeSlideId[_mode] = target.id;
      _boardFocused[_mode] = false;
      _draftStart = null;
      _draftEnd = null;
      _draftPoints = <Offset>[];
    });
    _scheduleSave();
  }

  Future<void> _renameSlide(BoardSlide slide) async {
    await _suspendPassThroughForOverlay();
    try {
      if (!mounted) return;
      final controller = TextEditingController(text: slide.title);
      final result = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Rename slide'),
          content: TextField(
            key: const ValueKey('slide-rename-field'),
            controller: controller,
            autofocus: true,
            maxLength: 30,
            decoration: const InputDecoration(hintText: 'Slide name'),
            onSubmitted: (value) => Navigator.pop(context, value),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, controller.text),
              child: const Text('Save'),
            ),
          ],
        ),
      );
      controller.dispose();
      if (!mounted || result == null) return;
      final trimmed = result.trim();
      if (trimmed.isEmpty) return;
      setState(() => slide.title = trimmed);
      _scheduleSave();
    } finally {
      await _resumePassThroughAfterOverlay();
      _scheduleHitTestSync();
    }
  }

  void _setToolbarDock(ToolbarDock dock) {
    if (_toolbarDock == dock) return;
    setState(() => _toolbarDock = dock);
    _scheduleSave();
    _scheduleHitTestSync();
  }

  void _removeSlot(ToolSlot slot) {
    if (_slots.length <= 1) return;
    final wasActive = _activeSlotId == slot.id;
    setState(() {
      _slots.removeWhere((item) => item.id == slot.id);
      if (_toolBeforeCollapse == slot.id) {
        _toolBeforeCollapse = _slots.first.id;
      }
    });
    if (wasActive) {
      unawaited(_setActiveSlot(_slots.first.id));
    } else {
      _scheduleSave();
    }
  }

  void _toggleSlot(ToolSlot slot) {
    unawaited(_setActiveSlot(_activeSlotId == slot.id ? null : slot.id));
  }

  void _selectSlot(ToolSlot slot) {
    unawaited(_setActiveSlot(slot.id));
  }

  void _selectEraser() {
    unawaited(
      _setActiveSlot(_activeSlotId == '__eraser__' ? null : '__eraser__'),
    );
  }

  void _selectMagnifier() {
    unawaited(
      _setActiveSlot(_activeSlotId == '__magnifier__' ? null : '__magnifier__'),
    );
  }

  void _selectPointerMode() {
    unawaited(_setActiveSlot(kPointerSlotId));
  }

  /// Right-click / tool toggle-off: normal OS cursor, no presentation ring.
  void _selectIdleDesktop() {
    unawaited(_setActiveSlot(null));
  }

  void _setMagnifierZoom(MagnifierZoom zoom) {
    if (_magnifierZoom == zoom) return;
    setState(() => _magnifierZoom = zoom);
    _scheduleSave();
    unawaited(_captureMagnifierFrame());
  }

  void _setMagnifierSize(MagnifierSize size) {
    if (_magnifierSize == size) return;
    setState(() => _magnifierSize = size);
    _scheduleSave();
    unawaited(_captureMagnifierFrame());
  }

  void _cycleRectangleSlots({required bool forward}) {
    final rectSlots = _slots
        .where((slot) => slot.type == ToolType.rectangle)
        .toList();
    if (rectSlots.length < 2) return;
    final currentIndex = rectSlots.indexWhere(
      (slot) => slot.id == _activeSlotId,
    );
    if (currentIndex < 0) return;
    final nextIndex = forward
        ? (currentIndex + 1) % rectSlots.length
        : (currentIndex - 1 + rectSlots.length) % rectSlots.length;
    unawaited(_setActiveSlot(rectSlots[nextIndex].id));
  }

  bool _shouldPanBoard() {
    if (!_isBoardMode) return false;
    if (_isMagnifierSelected) return false;
    if (_middlePanArmed) return true;
    if (_isPointerMode || _isIdleDesktop) return false;
    if (_isHandSelected) return true;
    return _panKeyHeldNow;
  }

  void _onCanvasPointerDown(PointerDownEvent event) {
    if (_passThroughOverlayDepth > 0) return;
    if ((event.buttons & kMiddleMouseButton) != 0) {
      if (_isBoardMode) {
        _middlePanArmed = true;
      }
      return;
    }
    if ((event.buttons & kSecondaryMouseButton) != 0) {
      if (_hasDrawingTool) {
        _selectIdleDesktop();
      }
      return;
    }
    if ((event.buttons & kBackMouseButton) != 0) {
      _cycleRectangleSlots(forward: false);
      return;
    }
    if ((event.buttons & kForwardMouseButton) != 0) {
      _cycleRectangleSlots(forward: true);
    }
  }

  Future<void> _setSidebarOpen(bool open) async {
    if (_sidebarOpen == open) return;
    if (!open) {
      if (_editingText) _commitInlineText();
      _toolBeforeCollapse = _activeSlotId ?? _toolBeforeCollapse;
      setState(() {
        _sidebarOpen = false;
        _paletteOpen = false;
      });
    } else {
      setState(() => _sidebarOpen = true);
    }
    await _syncPassThrough();
    _scheduleHitTestSync();
  }

  void _changeThickness(double value) {
    final slot = _selectedSlot;
    if (slot == null || slot.type == ToolType.text) return;
    setState(() => slot.thickness = value.clamp(1, 24).toDouble());
    _scheduleSave();
  }

  void _changeFontSize(double value) {
    final slot = _selectedSlot;
    if (slot == null || slot.type != ToolType.text) return;
    setState(() => slot.fontSize = value.clamp(12, 72).toDouble());
    _scheduleSave();
  }

  void _changeFill(bool value) {
    final slot = _selectedSlot;
    if (slot == null || slot.type != ToolType.rectangle) return;
    setState(() => slot.filled = value);
    _scheduleSave();
  }

  void _applyColor(Color color) {
    if (_isEraserSelected) return;
    final slot = _selectedSlot;
    if (slot == null) return;
    final nextColor = color.withValues(alpha: 1);
    setState(() {
      slot.color = nextColor;
      final pending = _pendingCandle;
      if (slot.type == ToolType.candlestick && pending != null) {
        _pendingCandle = CandleGroupDrawable(
          pending.candles,
          strokeWidth: pending.strokeWidth,
          bullColor: nextColor,
          bearColor: nextColor,
        );
      }
    });
    _scheduleSave();
  }

  void _syncShiftPressed() {
    final pressed = isShiftHeld();
    if (_shiftPressed == pressed) return;
    if (mounted) {
      setState(() => _shiftPressed = pressed);
    } else {
      _shiftPressed = pressed;
    }
  }

  void _startShiftPoll() {
    _shiftPollTimer?.cancel();
    _shiftPollTimer = Timer.periodic(const Duration(milliseconds: 16), (_) {
      if (_draftStart == null) {
        _stopShiftPoll();
        return;
      }
      _syncShiftPressed();
    });
  }

  void _stopShiftPoll() {
    _shiftPollTimer?.cancel();
    _shiftPollTimer = null;
  }

  void _commitPendingCandle() {
    final pending = _pendingCandle;
    if (pending == null) return;
    _pushUndo();
    _pendingCandle = null;
    _activeDrawables.add(pending);
    if (mounted) setState(() {});
    _scheduleSave();
  }

  CandleGroupDrawable _candleGroupFromSpecs(
    List<CandleSpec> candles,
    double thickness,
    Color color,
  ) {
    return CandleGroupDrawable(
      candles,
      strokeWidth: math.max(1, thickness / 4),
      bullColor: color,
      bearColor: color,
    );
  }

  void _startDrawing(DragStartDetails details) {
    if (_shouldPanBoard()) {
      _keyboardFocus.requestFocus();
      _isPanningBoard = true;
      _panStartLocal = details.localPosition;
      _panBase = _isBoardMode ? _cameraForPaint() : Offset.zero;
      _pointerPosition = details.localPosition;
      setState(() {
        if (_isBoardMode) _boardFocused[_mode] = false;
      });
      return;
    }
    if (!_hasDrawingTool) return;
    _keyboardFocus.requestFocus();
    _shiftPressed = isShiftHeld();
    _pointerPosition = details.localPosition;
    if (_isEraserSelected) {
      _eraserGestureChanged = false;
      _eraserPushedSlides.clear();
      _eraseAt(details.localPosition, grouped: true);
      return;
    }
    if (_activeSlot.type == ToolType.text) {
      return;
    }
    final local = _isBoardMode
        ? _screenToActiveLocal(details.localPosition)
        : details.localPosition;
    setState(() {
      _draftStart = local;
      _draftEnd = local;
      _draftPoints = <Offset>[local];
    });
    if (_activeSlot.type == ToolType.line) _startShiftPoll();
  }

  void _updateDrawing(DragUpdateDetails details) {
    if (_isPanningBoard) {
      final start = _panStartLocal;
      if (start != null) {
        _pointerPosition = details.localPosition;
        setState(() {
          _boardPan[_mode] = _panBase + (details.localPosition - start);
          if (_isBoardMode) _boardFocused[_mode] = false;
        });
      }
      return;
    }
    if (_shouldPanBoard()) {
      // Pan-key pressed mid-gesture: switch from drawing to moving.
      _isPanningBoard = true;
      _panStartLocal = details.localPosition;
      _panBase = _isBoardMode ? _cameraForPaint() : Offset.zero;
      _pointerPosition = details.localPosition;
      _stopShiftPoll();
      setState(() {
        if (_isBoardMode) _boardFocused[_mode] = false;
        _draftStart = null;
        _draftEnd = null;
        _draftPoints = <Offset>[];
      });
      return;
    }
    if (!_hasDrawingTool) return;
    _pointerPosition = details.localPosition;
    if (_isEraserSelected) {
      _eraseAt(details.localPosition, grouped: true);
      return;
    }
    if (_draftStart == null) return;
    final local = _isBoardMode
        ? _screenToActiveLocal(details.localPosition)
        : details.localPosition;
    final shiftPressed = isShiftHeld();
    setState(() {
      _shiftPressed = shiftPressed;
      _draftEnd = local;
      if (_activeSlot.type == ToolType.pen ||
          _activeSlot.type == ToolType.highlighter) {
        _draftPoints.add(local);
      }
    });
  }

  void _cancelDrawing() {
    _stopShiftPoll();
    if (_isPanningBoard) {
      _middlePanArmed = false;
      final reverted = _panBase;
      setState(() {
        _boardPan[_mode] = reverted;
        _isPanningBoard = false;
        _panStartLocal = null;
        if (_isBoardMode) {
          final snapped = cameraForSlide(
            _ensureActiveSlide(),
            _viewportSize,
          );
          _boardFocused[_mode] = (reverted - snapped).distance < 0.5;
        }
      });
      return;
    }
    _middlePanArmed = false;
    if (_draftStart == null && _draftEnd == null && _draftPoints.isEmpty) {
      return;
    }
    setState(() {
      _draftStart = null;
      _draftEnd = null;
      _draftPoints = <Offset>[];
    });
  }

  void _finishDrawing(DragEndDetails details) {
    _stopShiftPoll();
    if (_isPanningBoard) {
      _middlePanArmed = false;
      _panStartLocal = null;
      _commitBoardPan();
      return;
    }
    _middlePanArmed = false;
    if (!_hasDrawingTool) return;
    if (_isEraserSelected) {
      if (_eraserGestureChanged) _scheduleSave();
      _eraserGestureChanged = false;
      _eraserPushedSlides.clear();
      return;
    }
    if (_draftStart == null) return;
    _shiftPressed = isShiftHeld();
    final start = _draftStart!;
    final end = _effectiveLineEnd(_draftEnd ?? start);
    final slot = _activeSlot;
    final isFreehand =
        slot.type == ToolType.pen || slot.type == ToolType.highlighter;
    if (slot.type == ToolType.candlestick) {
      final pending = _pendingCandle;
      if (pending != null && pending.candles.isNotEmpty) {
        final body = pending.candles.first;
        final moved = (end - start).distance >= 2;
        final finished = moved ? applyCandleWicks(body, start, end) : body;
        _pushUndo();
        _activeDrawables.add(
          CandleGroupDrawable(
            [finished],
            strokeWidth: pending.strokeWidth,
            bullColor: slot.color,
            bearColor: slot.color,
          ),
        );
        setState(() {
          _pendingCandle = null;
          _draftStart = null;
          _draftEnd = null;
          _draftPoints = <Offset>[];
        });
        _scheduleSave();
        return;
      }
      if ((end - start).distance < 2) {
        setState(() {
          _draftStart = null;
          _draftEnd = null;
          _draftPoints = <Offset>[];
        });
        return;
      }
      setState(() {
        _pendingCandle = _candleGroupFromSpecs(
          [candleSpecFromBodyDrag(start, end, slot.thickness)],
          slot.thickness,
          slot.color,
        );
        _draftStart = null;
        _draftEnd = null;
        _draftPoints = <Offset>[];
      });
      return;
    }
    if ((end - start).distance < 2 && !isFreehand) {
      setState(() {
        _draftStart = null;
        _draftEnd = null;
        _draftPoints = <Offset>[];
      });
      return;
    }
    _pushUndo();
    final drawable = switch (slot.type) {
      ToolType.pen => StrokeDrawable(
        List<Offset>.from(_draftPoints),
        slot.drawingColor,
        slot.thickness,
      ),
      ToolType.highlighter => StrokeDrawable(
        List<Offset>.from(_draftPoints),
        slot.drawingColor,
        slot.thickness,
      ),
      ToolType.line => LineDrawable(
        start,
        end,
        slot.drawingColor,
        slot.thickness,
      ),
      ToolType.rectangle => RectangleDrawable(
        Rect.fromPoints(start, end),
        slot.drawingColor,
        slot.thickness,
        slot.filled,
      ),
      ToolType.text || ToolType.candlestick => null,
    };
    if (drawable != null) _activeDrawables.add(drawable);
    setState(() {
      _draftStart = null;
      _draftEnd = null;
      _draftPoints = <Offset>[];
    });
    _scheduleSave();
  }

  Offset _effectiveLineEnd(Offset end) {
    final start = _draftStart;
    if (start == null || _activeSlot.type != ToolType.line || !_shiftPressed) {
      return end;
    }
    return constrainLineToAxis(start, end);
  }

  void _canvasTap(TapUpDetails details) {
    if (_isHandSelected) return;
    if (!_hasDrawingTool) return;
    _pointerPosition = details.localPosition;
    final local = _isBoardMode
        ? _screenToActiveLocal(details.localPosition)
        : details.localPosition;
    if (_isEraserSelected) {
      _eraseAt(details.localPosition);
    } else if (_activeSlot.type == ToolType.text) {
      final preset = _activeSlot.placedPresetText;
      if (preset != null) {
        if (_editingText) _commitInlineText();
        _pushUndo();
        setState(
          () => _activeDrawables.add(
            TextDrawable(
              local,
              preset,
              _activeSlot.drawingColor,
              _activeSlot.fontSize,
            ),
          ),
        );
        _scheduleSave();
      } else {
        _beginInlineText(details.localPosition);
      }
    } else if (_activeSlot.type == ToolType.candlestick) {
      if (_pendingCandle != null) {
        _commitPendingCandle();
      } else {
        _pushUndo();
        setState(
          () => _activeDrawables.add(
            _candleGroupFromSpecs(
              [defaultCandleAt(local, _activeSlot.thickness)],
              _activeSlot.thickness,
              _activeSlot.color,
            ),
          ),
        );
        _scheduleSave();
      }
    } else if (_activeSlot.type == ToolType.pen ||
        _activeSlot.type == ToolType.highlighter) {
      _pushUndo();
      setState(
        () => _activeDrawables.add(
          StrokeDrawable(
            <Offset>[local],
            _activeSlot.drawingColor,
            _activeSlot.thickness,
          ),
        ),
      );
      _scheduleSave();
    }
  }

  void _beginInlineText(Offset position) {
    if (_editingText) _commitInlineText();
    setState(() {
      _editingText = true;
      _textOrigin = position;
      _textController.clear();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _textFocus.requestFocus();
    });
  }

  void _commitInlineText() {
    if (!_editingText) return;
    final text = _textController.text;
    final origin = _textOrigin;
    final slot = _selectedSlot;
    setState(() {
      _editingText = false;
      _textOrigin = null;
    });
    if (origin == null || slot == null || text.trim().isEmpty) return;
    final local = _isBoardMode ? _screenToActiveLocal(origin) : origin;
    _pushUndo();
    setState(
      () => _activeDrawables.add(
        TextDrawable(local, text.trim(), slot.drawingColor, slot.fontSize),
      ),
    );
    _scheduleSave();
  }

  void _cancelInlineText() {
    if (!_editingText) return;
    setState(() {
      _editingText = false;
      _textOrigin = null;
      _textController.clear();
    });
  }

  void _eraseAt(Offset screenPoint, {bool grouped = false}) {
    if (_mode == CanvasMode.screen) {
      for (var i = _activeDrawables.length - 1; i >= 0; i--) {
        if (_hitTest(_activeDrawables[i], screenPoint)) {
          if (!grouped || !_eraserGestureChanged) _pushUndo();
          setState(() => _activeDrawables.removeAt(i));
          if (grouped) {
            _eraserGestureChanged = true;
          } else {
            _scheduleSave();
          }
          return;
        }
      }
      return;
    }
    // Board mode: erase whatever tile is under the pointer, even while
    // roaming between tiles. Each tile keeps its own undo history.
    final size = _viewportSize;
    final camera = _isBoardFocused
        ? cameraForSlide(_ensureActiveSlide(), size)
        : _activePan;
    final slides = _slidesFor(_mode);
    for (final slide in slides) {
      final origin = boardSlideOrigin(
        col: slide.col,
        row: slide.row,
        viewport: size,
      );
      final local = screenPoint - camera - origin;
      for (var i = slide.drawables.length - 1; i >= 0; i--) {
        if (_hitTest(slide.drawables[i], local)) {
          final needsPush =
              !grouped || _eraserPushedSlides.add(slide.id);
          if (needsPush) _pushUndoFor(slide);
          setState(() => slide.drawables.removeAt(i));
          if (grouped) {
            _eraserGestureChanged = true;
          } else {
            _scheduleSave();
          }
          return;
        }
      }
    }
  }

  bool _hitTest(Drawable item, Offset point) {
    const tolerance = 12.0;
    switch (item) {
      case StrokeDrawable():
        if (item.points.isEmpty) return false;
        if (item.points.length == 1) {
          return (item.points.first - point).distance <=
              tolerance + item.width / 2;
        }
        for (var i = 1; i < item.points.length; i++) {
          if (_distanceToSegment(point, item.points[i - 1], item.points[i]) <=
              tolerance + item.width / 2) {
            return true;
          }
        }
        return false;
      case LineDrawable():
        return _distanceToSegment(point, item.start, item.end) <=
            tolerance + item.width;
      case RectangleDrawable():
        return item.rect.inflate(tolerance + item.width).contains(point);
      case TextDrawable():
        final rect = Rect.fromLTWH(
          item.position.dx,
          item.position.dy,
          item.text.length * item.fontSize * .65,
          item.fontSize * 1.2,
        );
        return rect.inflate(tolerance).contains(point);
      case CandleGroupDrawable():
        return candleGroupBounds(
          item.candles,
        ).inflate(tolerance + item.strokeWidth).contains(point);
    }
    return false;
  }

  double _distanceToSegment(Offset p, Offset a, Offset b) {
    final dx = b.dx - a.dx;
    final dy = b.dy - a.dy;
    if (dx == 0 && dy == 0) return (p - a).distance;
    final t = ((p.dx - a.dx) * dx + (p.dy - a.dy) * dy) / (dx * dx + dy * dy);
    final clamped = t.clamp(0, 1);
    return (p - Offset(a.dx + clamped * dx, a.dy + clamped * dy)).distance;
  }

  Future<void> _takeScreenshot() async {
    try {
      final boundary =
          _canvasKey.currentContext?.findRenderObject()
              as RenderRepaintBoundary?;
      if (boundary == null) return;
      final image = await boundary.toImage(
        pixelRatio: MediaQuery.devicePixelRatioOf(context),
      );
      final data = await image
          .toByteData(format: ui.ImageByteFormat.png)
          .whenComplete(image.dispose);
      if (data == null) throw StateError('Could not encode the canvas');
      final folder = Directory(
        _screenshotFolder.isEmpty
            ? _defaultScreenshotFolder
            : _screenshotFolder,
      );
      await folder.create(recursive: true);
      final stamp = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '-')
          .split('.')
          .first;
      final file = File(
        '${folder.path}${Platform.pathSeparator}pen-$stamp.png',
      );
      await file.writeAsBytes(data.buffer.asUint8List());
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Screenshot saved to ${file.path}')),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not save screenshot: $error')),
        );
      }
    }
  }

  Future<void> _chooseScreenshotFolder() async {
    await _suspendPassThroughForOverlay();
    try {
      String? initial;
      if (_screenshotFolder.isNotEmpty) {
        try {
          if (Directory(_screenshotFolder).existsSync()) {
            initial = _screenshotFolder;
          }
        } catch (_) {}
      }
      String? selected;
      if (Platform.isWindows) {
        try {
          await windowManager.setAlwaysOnTop(false);
        } catch (_) {}
        var useFilePickerFallback = false;
        try {
          final raw = await _nativeChannel.invokeMethod<dynamic>(
            'pickDirectory',
            <String, String?>{
              'dialogTitle': 'Choose screenshot folder',
              'initialDirectory': initial,
            },
          );
          if (raw is Map) {
            final map = Map<Object?, Object?>.from(raw);
            if (map['ok'] == true) {
              final path = map['path'];
              if (path is String && path.isNotEmpty) {
                selected = path;
              } else {
                useFilePickerFallback = true;
              }
            } else if (map['cancelled'] == true) {
              selected = null;
            } else {
              useFilePickerFallback = true;
            }
          } else {
            // Legacy null/string reply — treat successful channel as final.
            if (raw is String && raw.isNotEmpty) {
              selected = raw;
            } else {
              selected = null;
            }
          }
        } catch (_) {
          useFilePickerFallback = true;
        }
        if (useFilePickerFallback) {
          try {
            selected = await FilePicker.getDirectoryPath(
              dialogTitle: 'Choose screenshot folder',
              initialDirectory: initial,
              lockParentWindow: true,
            );
          } catch (_) {
            try {
              selected = await FilePicker.getDirectoryPath(
                dialogTitle: 'Choose screenshot folder',
                lockParentWindow: true,
              );
            } catch (_) {
              selected = null;
            }
          }
        }
        try {
          await windowManager.setAlwaysOnTop(true);
        } catch (_) {}
        unawaited(_fitOverlayToCurrentDisplay());
      } else {
        try {
          selected = await FilePicker.getDirectoryPath(
            dialogTitle: 'Choose screenshot folder',
            initialDirectory: initial,
          );
        } catch (_) {
          selected = null;
        }
      }
      if (!mounted || selected == null || selected.isEmpty) return;
      setState(() => _screenshotFolder = selected!);
      _scheduleSave();
    } finally {
      await _resumePassThroughAfterOverlay();
    }
  }

  Future<void> _addSlot() async {
    await _suspendPassThroughForOverlay();
    try {
      if (!mounted) return;
      final result = await showDialog<ToolSlot>(
        context: context,
        builder: (context) => const _AddSlotDialog(),
      );
      if (!mounted || result == null) return;
      final suffix = _slots.where((s) => s.type == result.type).length + 1;
      final newSlot = ToolSlot(
        id: '${result.type.name}-${DateTime.now().microsecondsSinceEpoch}',
        type: result.type,
        color: result.color,
        thickness: result.thickness,
        filled: result.filled,
        fontSize: result.fontSize,
        presetText: result.presetText,
      );
      setState(() {
        _slots.add(newSlot);
      });
      unawaited(_setActiveSlot(newSlot.id));
      if (mounted) {
        final label = result.toolbarTitle ?? result.type.label;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$label slot $suffix added')));
      }
    } finally {
      await _resumePassThroughAfterOverlay();
    }
  }

  Future<void> _showSettings() async {
    await _suspendPassThroughForOverlay();
    try {
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            title: const Row(
              children: [
                Icon(Icons.tune, size: 20),
                SizedBox(width: 10),
                Text('Settings'),
              ],
            ),
            content: SizedBox(
              width: 520,
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const _SettingSectionTitle('About'),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Screen pen by Hamed Mosaddeghian'),
                      subtitle: Text(
                        'Version $kAppVersion',
                        key: const ValueKey('app-version'),
                      ),
                    ),
                    const Divider(),
                    const _SettingSectionTitle('General'),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Remember content after exit'),
                      value: _rememberContent,
                      onChanged: (value) {
                        setDialogState(() => _rememberContent = value);
                        setState(() {});
                      },
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Cover the Windows taskbar'),
                      subtitle: const Text(
                        'Expand the active-display overlay to the full monitor',
                      ),
                      value: _coverTaskbar,
                      onChanged: (value) {
                        setDialogState(() => _coverTaskbar = value);
                        setState(() {});
                        unawaited(_fitOverlayToCurrentDisplay());
                      },
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Presentation cursor'),
                      subtitle: const Text(
                        'Also show the pointer halo while drawing',
                      ),
                      value: _presentationCursor,
                      onChanged: (value) {
                        setDialogState(() => _presentationCursor = value);
                        setState(() {});
                      },
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Expanded quick colors'),
                      value: _expandedColors,
                      onChanged: (value) {
                        setDialogState(() => _expandedColors = value);
                        setState(() {});
                      },
                    ),
                    const Divider(),
                    const _SettingSectionTitle('Board moving'),
                    const Text(
                      'Hold this key and drag to move endless whiteboard/blackboard. The Hand tool always moves.',
                      style: TextStyle(fontSize: 12, color: Colors.white60),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      children: [
                        for (final key in BoardPanKey.values)
                          ChoiceChip(
                            key: ValueKey('pan-key-${key.name}'),
                            label: Text(key.label),
                            selected: _panKey == key,
                            onSelected: (_) {
                              setDialogState(() => _panKey = key);
                              setState(() {});
                            },
                          ),
                      ],
                    ),
                    const Divider(),
                    const _SettingSectionTitle('Screenshots'),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Screenshot folder'),
                      subtitle: Text(_screenshotFolder),
                      trailing: OutlinedButton(
                        onPressed: () async {
                          await _chooseScreenshotFolder();
                          setDialogState(() {});
                        },
                        child: const Text('Choose'),
                      ),
                    ),
                    const Divider(),
                    const _SettingSectionTitle('Tool slots'),
                    ..._slots.map(
                      (slot) => ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: slot.type.icon != null
                            ? Icon(slot.type.icon, color: slot.color)
                            : ColorFiltered(
                                colorFilter: ColorFilter.mode(
                                  slot.color,
                                  BlendMode.srcATop,
                                ),
                                child: slot.type.toolbarIcon,
                              ),
                        title: Text(slot.toolbarTitle ?? slot.type.label),
                        subtitle: Text(switch (slot.type) {
                          ToolType.text =>
                            '${slot.fontSize.toStringAsFixed(0)} px text',
                          ToolType.rectangle =>
                            '${slot.thickness.toStringAsFixed(0)} px  •  '
                                '${slot.filled ? 'Filled' : 'Outline'}',
                          ToolType.candlestick =>
                            '${slot.thickness.toStringAsFixed(0)} px candle',
                          _ => '${slot.thickness.toStringAsFixed(0)} px',
                        }),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              key: ValueKey('remove-tool-${slot.id}'),
                              tooltip: 'Remove tool',
                              onPressed: _slots.length <= 1
                                  ? null
                                  : () {
                                      _removeSlot(slot);
                                      setDialogState(() {});
                                    },
                              icon: const Icon(Icons.delete_outline),
                            ),
                            IconButton(
                              tooltip: 'Select slot',
                              onPressed: () {
                                _selectSlot(slot);
                                setDialogState(() {});
                              },
                              icon: Icon(
                                _activeSlotId == slot.id
                                    ? Icons.radio_button_checked
                                    : Icons.radio_button_off,
                                color: _activeSlotId == slot.id
                                    ? Theme.of(context).colorScheme.primary
                                    : null,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    OutlinedButton.icon(
                      onPressed: () async {
                        Navigator.pop(context);
                        await _addSlot();
                      },
                      icon: const Icon(Icons.add),
                      label: const Text('Add another tool slot'),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Hotkeys: Ctrl+Shift+P Pointer  •  Ctrl+Shift+H Toolbar  '
                      '•  Ctrl+Shift+Z Undo  •  Ctrl+Shift+Q Exit',
                      style: TextStyle(fontSize: 12, color: Colors.white60),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () {
                  _scheduleSave();
                  Navigator.pop(context);
                },
                child: const Text('Done'),
              ),
            ],
          ),
        ),
      );
      _scheduleSave();
    } finally {
      await _resumePassThroughAfterOverlay();
    }
  }

  void _handleKey(KeyEvent event) {
    if (_isShiftLogicalKey(event.logicalKey)) {
      _syncShiftPressed();
      return;
    }
    if (_editingText) {
      if (event is KeyDownEvent &&
          event.logicalKey == LogicalKeyboardKey.escape) {
        _cancelInlineText();
      }
      return;
    }
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape) {
      _commitPendingCandle();
      if (_isPanningBoard) {
        final reverted = _panBase;
        setState(() {
          _boardPan[_mode] = reverted;
          _isPanningBoard = false;
          _panStartLocal = null;
          if (_isBoardMode) {
            final snapped = cameraForSlide(
              _ensureActiveSlide(),
              _viewportSize,
            );
            _boardFocused[_mode] = (reverted - snapped).distance < 0.5;
          }
        });
      }
      return;
    }
    if (event is! KeyDownEvent) return;
    final isCtrlShift =
        HardwareKeyboard.instance.isControlPressed &&
        HardwareKeyboard.instance.isShiftPressed;
    if (isCtrlShift) {
      switch (event.logicalKey) {
        case LogicalKeyboardKey.keyW:
          _selectMode(CanvasMode.whiteboard);
        case LogicalKeyboardKey.keyB:
          _selectMode(CanvasMode.blackboard);
        case LogicalKeyboardKey.keyZ:
          _undoLast();
        case LogicalKeyboardKey.keyS:
          unawaited(_takeScreenshot());
        case LogicalKeyboardKey.keyH:
          unawaited(_setSidebarOpen(!_sidebarOpen));
        case LogicalKeyboardKey.keyP:
          unawaited(_togglePointerMode());
        case LogicalKeyboardKey.keyQ:
          unawaited(_shutdown());
      }
      return;
    }
    // Endless tile map shortcuts (no Ctrl+Shift needed).
    if (!_isBoardMode) return;
    final noModifiers =
        !HardwareKeyboard.instance.isControlPressed &&
        !HardwareKeyboard.instance.isAltPressed;
    if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      _stepSlideBy(1, 0);
    } else if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      _stepSlideBy(-1, 0);
    } else if (event.logicalKey == LogicalKeyboardKey.arrowDown ||
        event.logicalKey == LogicalKeyboardKey.pageDown) {
      _stepSlideBy(0, 1);
    } else if (event.logicalKey == LogicalKeyboardKey.arrowUp ||
        event.logicalKey == LogicalKeyboardKey.pageUp) {
      _stepSlideBy(0, -1);
    } else if (noModifiers && event.logicalKey == LogicalKeyboardKey.keyH) {
      _selectHand();
    }
  }

  Positioned _toolbarPositioned({required Widget child}) {
    return switch (_toolbarDock) {
      ToolbarDock.left => Positioned(left: 0, top: 0, bottom: 0, child: child),
      ToolbarDock.right => Positioned(
        right: 0,
        top: 0,
        bottom: 0,
        child: child,
      ),
      ToolbarDock.top => Positioned(left: 0, right: 0, top: 0, child: child),
      ToolbarDock.bottom => Positioned(
        left: 0,
        right: 0,
        bottom: 0,
        child: child,
      ),
    };
  }

  Positioned _restorePositioned({required Widget child}) {
    return switch (_toolbarDock) {
      ToolbarDock.left => Positioned(left: 0, top: 72, child: child),
      ToolbarDock.right => Positioned(right: 0, top: 72, child: child),
      ToolbarDock.top => Positioned(left: 72, top: 0, child: child),
      ToolbarDock.bottom => Positioned(left: 72, bottom: 0, child: child),
    };
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const ColoredBox(
        color: Colors.transparent,
        child: SizedBox.expand(),
      );
    }
    final boardColor = switch (_mode) {
      CanvasMode.screen => Colors.transparent,
      CanvasMode.whiteboard => Colors.white,
      CanvasMode.blackboard => Colors.black,
    };
    final annotationActive =
        (_hasDrawingTool || _isHandSelected) &&
        _sidebarOpen &&
        !_isMagnifierSelected &&
        !_isPointerMode;
    final toolCursorKind = annotationActive
        ? (_isHandSelected
              ? null
              : _isEraserSelected
              ? ToolCursorKind.eraser
              : switch (_activeSlot.type) {
                  ToolType.pen => ToolCursorKind.pen,
                  ToolType.highlighter => ToolCursorKind.highlighter,
                  ToolType.text => ToolCursorKind.text,
                  ToolType.line => ToolCursorKind.line,
                  ToolType.rectangle => ToolCursorKind.rectangle,
                  ToolType.candlestick => ToolCursorKind.candlestick,
                })
        : null;
    // Explicit Pointer tool keeps the presentation ring. Idle desktop (right-
    // click deselect / tool toggle-off) uses a normal OS cursor with no halo.
    final showPointerRing =
        _isPointerMode || (_presentationCursor && annotationActive);
    final media = MediaQuery.of(context);
    return MediaQuery(
      data: media.copyWith(
        padding: EdgeInsets.zero,
        viewPadding: EdgeInsets.zero,
        viewInsets: EdgeInsets.zero,
      ),
      child: KeyboardListener(
        focusNode: _keyboardFocus,
        autofocus: true,
        onKeyEvent: _handleKey,
        child: Scaffold(
          backgroundColor: Colors.transparent,
          body: Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: _onCanvasPointerDown,
            child: Stack(
              fit: StackFit.expand,
              children: [
                RepaintBoundary(
                  key: _canvasKey,
                  child: ColoredBox(
                    color: boardColor,
                    child: MouseRegion(
                      // Normal arrow stays visible; the tool icon is painted
                      // beside it so the arrow tip shows the exact draw point.
                      cursor: _isMagnifierSelected
                          ? SystemMouseCursors.none
                          : _isHandSelected || _isPanningBoard
                          ? SystemMouseCursors.move
                          : SystemMouseCursors.basic,
                      onHover: (event) {
                        if (!annotationActive &&
                            !showPointerRing &&
                            !_isMagnifierSelected) {
                          return;
                        }
                        setState(() => _pointerPosition = event.localPosition);
                      },
                      onExit: (_) {
                        if (!_passThrough && !_isMagnifierSelected) {
                          setState(() => _pointerPosition = null);
                        }
                      },
                      child: IgnorePointer(
                        ignoring:
                            !annotationActive ||
                            _editingText ||
                            _isMagnifierSelected,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTapUp: _canvasTap,
                          onPanStart: _startDrawing,
                          onPanUpdate: _updateDrawing,
                          onPanEnd: _finishDrawing,
                          onPanCancel: _cancelDrawing,
                          child: CustomPaint(
                            painter: AnnotationPainter(
                              drawables: _activeDrawables,
                              draftPoints: _draftPoints,
                              draftStart: _draftStart,
                              draftEnd: _previewLineEnd,
                              draftSlot:
                                  _hasDrawingTool &&
                                      !_isEraserSelected &&
                                      !_isMagnifierSelected
                                  ? _activeSlot
                                  : _slots.first,
                              pendingCandle: _pendingCandle,
                              pointerPosition: _pointerPosition,
                              showPointer: showPointerRing,
                              toolCursorKind: toolCursorKind,
                              toolCursorColor: _isEraserSelected
                                  ? const Color(0xffff7082)
                                  : _selectedSlot?.color,
                              magnifierImage: _isMagnifierSelected
                                  ? _magnifierImage
                                  : null,
                              magnifierCenter: _isMagnifierSelected
                                  ? _pointerPosition
                                  : null,
                              magnifierLensSize: _magnifierSize.lensSize,
                              panOffset: _isBoardMode ? _activePan : Offset.zero,
                              boardSlides: _isBoardMode
                                  ? _activeSlides
                                  : null,
                              activeBoardSlideId: _isBoardMode
                                  ? _activeSlideId[_mode]
                                  : null,
                              boardCamera: _isBoardMode
                                  ? _cameraForPaint()
                                  : Offset.zero,
                              boardFocused: _isBoardFocused,
                              boardGap: kBoardSlideGap,
                            ),
                            child: const SizedBox.expand(),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                if (_editingText && _textOrigin != null)
                  Positioned(
                    left: _textOrigin!.dx,
                    top: _textOrigin!.dy,
                    child: Material(
                      color: Colors.transparent,
                      child: SizedBox(
                        width: 480,
                        child: TextField(
                          key: const ValueKey('inline-text-field'),
                          controller: _textController,
                          focusNode: _textFocus,
                          autofocus: true,
                          cursorColor: _selectedSlot?.color ?? Colors.white,
                          style: TextStyle(
                            color: _selectedSlot?.drawingColor ?? Colors.white,
                            fontSize: _selectedSlot?.fontSize ?? 24,
                            fontWeight: FontWeight.w600,
                          ),
                          decoration: const InputDecoration(
                            isDense: true,
                            border: InputBorder.none,
                            hintText: '',
                          ),
                          onSubmitted: (_) => _commitInlineText(),
                          onTapOutside: (_) => _commitInlineText(),
                        ),
                      ),
                    ),
                  ),
                if (_sidebarOpen)
                  _toolbarPositioned(
                    child: KeyedSubtree(
                      key: _toolbarKey,
                      child: _Sidebar(
                        dock: _toolbarDock,
                        mode: _mode,
                        slots: _slots,
                        activeSlotId: _activeSlotId,
                        paletteOpen: _paletteOpen,
                        quickColors: _quickColors,
                        expandedColors: _expandedColors,
                        selectedColor: _selectedSlot?.color,
                        magnifierZoom: _magnifierZoom,
                        magnifierSize: _magnifierSize,
                        onDrag: () => unawaited(_dragToolbar()),
                        onDock: _setToolbarDock,
                        onOverlayMenuOpen: () =>
                            unawaited(_suspendPassThroughForOverlay()),
                        onOverlayMenuClose: () =>
                            unawaited(_resumePassThroughAfterOverlay()),
                        onPointer: _selectPointerMode,
                        onMode: _selectMode,
                        onSlot: _toggleSlot,
                        onHand: _selectHand,
                        onEraser: _selectEraser,
                        onMagnifier: _selectMagnifier,
                        onMagnifierZoom: _setMagnifierZoom,
                        onMagnifierSize: _setMagnifierSize,
                        onColor: _applyColor,
                        onTogglePalette: () {
                          setState(() => _paletteOpen = !_paletteOpen);
                          _scheduleHitTestSync();
                        },
                        onUndo: _undoLast,
                        onClear: _clearCanvas,
                        onScreenshot: () => unawaited(_takeScreenshot()),
                        onSettings: () => unawaited(_showSettings()),
                        onAddSlot: () => unawaited(_addSlot()),
                        onHide: () => unawaited(_setSidebarOpen(false)),
                        onExit: () => unawaited(_shutdown()),
                        onChangeThickness: _changeThickness,
                        onChangeFontSize: _changeFontSize,
                        onChangeFill: _changeFill,
                      ),
                    ),
                  )
                else
                  _restorePositioned(
                    child: Material(
                      key: _restoreKey,
                      color: const Color(0xff202735),
                      borderRadius: switch (_toolbarDock) {
                        ToolbarDock.left => const BorderRadius.horizontal(
                          right: Radius.circular(12),
                        ),
                        ToolbarDock.right => const BorderRadius.horizontal(
                          left: Radius.circular(12),
                        ),
                        ToolbarDock.top => const BorderRadius.vertical(
                          bottom: Radius.circular(12),
                        ),
                        ToolbarDock.bottom => const BorderRadius.vertical(
                          top: Radius.circular(12),
                        ),
                      },
                      child: IconButton(
                        tooltip: 'Show toolbar (Ctrl+Shift+H)',
                        onPressed: () => unawaited(_setSidebarOpen(true)),
                        icon: Icon(switch (_toolbarDock) {
                          ToolbarDock.left => Icons.chevron_right,
                          ToolbarDock.right => Icons.chevron_left,
                          ToolbarDock.top => Icons.expand_more,
                          ToolbarDock.bottom => Icons.expand_less,
                        }),
                      ),
                    ),
                  ),
                if (_isBoardMode)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom:
                        (_toolbarDock == ToolbarDock.bottom && _sidebarOpen)
                        ? 68
                        : 12,
                    child: Center(
                      child: KeyedSubtree(
                        key: _slideBarKey,
                        child: _BoardSlideBar(
                          slides: _activeSlides,
                          activeId: _activeSlideId[_mode],
                          onSelect: _selectSlide,
                          onAdd: _addSlide,
                          onPrevious: () => _stepSlideBy(-1, 0),
                          onNext: () => _stepSlideBy(1, 0),
                          onUp: () => _stepSlideBy(0, -1),
                          onDown: () => _stepSlideBy(0, 1),
                          onRename: _renameSlide,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

enum ToolCursorKind {
  pen,
  highlighter,
  eraser,
  line,
  rectangle,
  text,
  candlestick,
}

class AnnotationPainter extends CustomPainter {
  const AnnotationPainter({
    required this.drawables,
    required this.draftPoints,
    required this.draftStart,
    required this.draftEnd,
    required this.draftSlot,
    this.pendingCandle,
    required this.pointerPosition,
    required this.showPointer,
    this.toolCursorKind,
    this.toolCursorColor,
    this.magnifierImage,
    this.magnifierCenter,
    this.magnifierLensSize = const Size(220, 150),
    this.panOffset = Offset.zero,
    this.boardSlides,
    this.activeBoardSlideId,
    this.boardCamera = Offset.zero,
    this.boardFocused = true,
    this.boardGap = kBoardSlideGap,
  });

  final List<Drawable> drawables;
  final List<Offset> draftPoints;
  final Offset? draftStart;
  final Offset? draftEnd;
  final ToolSlot draftSlot;
  final CandleGroupDrawable? pendingCandle;
  final Offset? pointerPosition;
  final bool showPointer;
  final ToolCursorKind? toolCursorKind;
  final Color? toolCursorColor;
  final ui.Image? magnifierImage;
  final Offset? magnifierCenter;
  final Size magnifierLensSize;
  final Offset panOffset;

  /// All tiles for endless board map. Null means single canvas (screen mode
  /// or old tests). When set, tiles are laid out as a grid with gaps.
  final List<BoardSlide>? boardSlides;
  final String? activeBoardSlideId;

  /// Free camera (screen = board + camera). Focused view snaps to the active
  /// tile and clips to its borders; roaming shows all tiles including gaps.
  final Offset boardCamera;
  final bool boardFocused;
  final double boardGap;

  BoardSlide? get _activeBoardSlide {
    final slides = boardSlides;
    if (slides == null || slides.isEmpty) return null;
    for (final slide in slides) {
      if (slide.id == activeBoardSlideId) return slide;
    }
    return slides.first;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final slides = boardSlides;
    if (slides != null && slides.isNotEmpty) {
      _paintBoard(canvas, size, slides);
    } else {
      canvas.save();
      // Single canvas (screen mode): shift without borders.
      canvas.translate(panOffset.dx, panOffset.dy);
      for (final item in drawables) {
        _paintDrawable(canvas, item);
      }
      if (pendingCandle != null) {
        _paintDrawable(canvas, pendingCandle!);
      }
      _paintDraft(canvas);
      canvas.restore();
    }
    if (showPointer && pointerPosition != null) {
      final halo = Paint()
        ..color = const Color(0xff35a7ff).withValues(alpha: .22);
      final ring = Paint()
        ..color = const Color(0xff35a7ff)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5;
      final center = Paint()..color = Colors.white;
      canvas.drawCircle(pointerPosition!, 20, halo);
      canvas.drawCircle(pointerPosition!, 20, ring);
      canvas.drawCircle(pointerPosition!, 3.5, center);
    }
    if (magnifierImage != null && magnifierCenter != null) {
      final lens = Rect.fromCenter(
        center: magnifierCenter!,
        width: magnifierLensSize.width,
        height: magnifierLensSize.height,
      );
      canvas.save();
      canvas.clipRRect(RRect.fromRectAndRadius(lens, const Radius.circular(6)));
      paintImage(
        canvas: canvas,
        rect: lens,
        image: magnifierImage!,
        fit: BoxFit.fill,
        filterQuality: FilterQuality.medium,
      );
      canvas.restore();
      canvas.drawRRect(
        RRect.fromRectAndRadius(lens, const Radius.circular(6)),
        Paint()
          ..color = const Color(0xff35a7ff)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(lens.inflate(1), const Radius.circular(7)),
        Paint()
          ..color = Colors.black45
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
    }
    if (toolCursorKind != null && pointerPosition != null) {
      _paintToolCursor(
        canvas,
        pointerPosition!,
        toolCursorKind!,
        toolCursorColor,
      );
    }
  }

  void _paintBoard(Canvas canvas, Size size, List<BoardSlide> slides) {
    final active = _activeBoardSlide;
    final camera = boardFocused && active != null
        ? -boardSlideOrigin(
            col: active.col,
            row: active.row,
            viewport: size,
            gap: boardGap,
          )
        : boardCamera;
    if (boardFocused && active != null) {
      // Focused (tap a number): show only inside this tile's borders.
      final origin = boardSlideOrigin(
        col: active.col,
        row: active.row,
        viewport: size,
        gap: boardGap,
      );
      final rect = Rect.fromLTWH(
        origin.dx + camera.dx,
        origin.dy + camera.dy,
        size.width,
        size.height,
      );
      canvas.save();
      canvas.clipRect(rect);
      canvas.translate(origin.dx + camera.dx, origin.dy + camera.dy);
      for (final item in active.drawables) {
        _paintDrawable(canvas, item);
      }
      if (pendingCandle != null) {
        _paintDrawable(canvas, pendingCandle!);
      }
      _paintDraft(canvas);
      canvas.restore();
      _paintSlideFrame(canvas, rect, active, isActive: true);
      return;
    }
    // Roaming (dragging between tiles): show everything, even gaps.
    // No clipping so ink that spills over borders stays visible.
    for (final slide in slides) {
      final origin = boardSlideOrigin(
        col: slide.col,
        row: slide.row,
        viewport: size,
        gap: boardGap,
      );
      canvas.save();
      canvas.translate(origin.dx + camera.dx, origin.dy + camera.dy);
      for (final item in slide.drawables) {
        _paintDrawable(canvas, item);
      }
      if (slide.id == active?.id && pendingCandle != null) {
        _paintDrawable(canvas, pendingCandle!);
      }
      if (slide.id == active?.id) {
        _paintDraft(canvas);
      }
      canvas.restore();
    }
    for (final slide in slides) {
      final origin = boardSlideOrigin(
        col: slide.col,
        row: slide.row,
        viewport: size,
        gap: boardGap,
      );
      final rect = Rect.fromLTWH(
        origin.dx + camera.dx,
        origin.dy + camera.dy,
        size.width,
        size.height,
      );
      // Skip far off-screen tiles for speed.
      if (rect.right < -200 ||
          rect.bottom < -200 ||
          rect.left > size.width + 200 ||
          rect.top > size.height + 200) {
        continue;
      }
      _paintSlideFrame(canvas, rect, slide, isActive: slide.id == active?.id);
    }
  }

  void _paintSlideFrame(
    Canvas canvas,
    Rect rect,
    BoardSlide slide, {
    required bool isActive,
  }) {
    final border = Paint()
      ..color = isActive
          ? const Color(0xff2d8ac7)
          : const Color(0xff9aa3b2).withValues(alpha: .65)
      ..style = PaintingStyle.stroke
      ..strokeWidth = isActive ? 3 : 1.5;
    canvas.drawRect(rect, border);
    final label = slide.title.isEmpty ? '?' : slide.title;
    final text = TextPainter(
      text: TextSpan(
        text: label,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 13,
          fontWeight: FontWeight.w700,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    const padding = 6.0;
    final pill = RRect.fromRectAndRadius(
      Rect.fromLTWH(
        rect.left + 8,
        rect.top + 8,
        text.width + padding * 2,
        text.height + padding,
      ),
      const Radius.circular(8),
    );
    canvas.drawRRect(
      pill,
      Paint()..color = const Color(0xff202735).withValues(alpha: .92),
    );
    canvas.drawRRect(
      pill,
      Paint()
        ..color = isActive
            ? const Color(0xff2d8ac7)
            : Colors.white24
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2,
    );
    text.paint(
      canvas,
      Offset(pill.left + padding, pill.top + padding / 2),
    );
  }

  void _paintDraft(Canvas canvas) {
    if (draftStart != null && draftEnd != null) {
      switch (draftSlot.type) {
        case ToolType.pen:
          _paintDrawable(
            canvas,
            StrokeDrawable(
              draftPoints,
              draftSlot.drawingColor,
              draftSlot.thickness,
            ),
          );
        case ToolType.highlighter:
          _paintDrawable(
            canvas,
            StrokeDrawable(
              draftPoints,
              draftSlot.drawingColor,
              draftSlot.thickness,
            ),
          );
        case ToolType.line:
          _paintDrawable(
            canvas,
            LineDrawable(
              draftStart!,
              draftEnd!,
              draftSlot.drawingColor,
              draftSlot.thickness,
            ),
          );
        case ToolType.rectangle:
          _paintDrawable(
            canvas,
            RectangleDrawable(
              Rect.fromPoints(draftStart!, draftEnd!),
              draftSlot.drawingColor,
              draftSlot.thickness,
              draftSlot.filled,
            ),
          );
        case ToolType.text:
          break;
        case ToolType.candlestick:
          final pending = pendingCandle;
          if (pending != null && pending.candles.isNotEmpty) {
            _paintDrawable(
              canvas,
              CandleGroupDrawable(
                [
                  applyCandleWicks(
                    pending.candles.first,
                    draftStart!,
                    draftEnd!,
                  ),
                ],
                strokeWidth: pending.strokeWidth,
                bullColor: draftSlot.color,
                bearColor: draftSlot.color,
              ),
            );
          } else {
            _paintDrawable(
              canvas,
              CandleGroupDrawable(
                [
                  candleSpecFromBodyDrag(
                    draftStart!,
                    draftEnd!,
                    draftSlot.thickness,
                  ),
                ],
                strokeWidth: math.max(1, draftSlot.thickness / 4),
                bullColor: draftSlot.color,
                bearColor: draftSlot.color,
              ),
            );
          }
      }
    } else if (pendingCandle != null && boardSlides == null) {
      _paintDrawable(canvas, pendingCandle!);
    }
  }

  void _paintToolCursor(
    Canvas canvas,
    Offset position,
    ToolCursorKind kind,
    Color? color,
  ) {
    final ink = color ?? const Color(0xff35a7ff);
    // The normal OS arrow is visible with its tip at [position], so each
    // preview sits beside the arrow instead of under it. The arrow tip
    // itself marks the exact draw point.
    switch (kind) {
      case ToolCursorKind.pen:
        final path = Path()
          ..moveTo(position.dx + 14, position.dy + 22)
          ..lineTo(position.dx + 22, position.dy + 14)
          ..lineTo(position.dx + 26, position.dy + 18)
          ..lineTo(position.dx + 18, position.dy + 26)
          ..close();
        canvas.drawPath(path, Paint()..color = ink);
        canvas.drawCircle(position, 1.8, Paint()..color = ink);
      case ToolCursorKind.highlighter:
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(
              center: position.translate(20, 18),
              width: 14,
              height: 8,
            ),
            const Radius.circular(2),
          ),
          Paint()..color = ink.withValues(alpha: .55),
        );
        canvas.drawCircle(position, 2, Paint()..color = ink);
      case ToolCursorKind.eraser:
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(
              center: position.translate(19, 18),
              width: 14,
              height: 10,
            ),
            const Radius.circular(2),
          ),
          Paint()..color = const Color(0xffff7082),
        );
      case ToolCursorKind.line:
        canvas.drawLine(
          position,
          position.translate(16, 0),
          Paint()
            ..color = ink
            ..strokeWidth = 2
            ..strokeCap = StrokeCap.round,
        );
      case ToolCursorKind.rectangle:
        canvas.drawRect(
          Rect.fromLTWH(position.dx, position.dy, 14, 10),
          Paint()
            ..color = ink
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.6,
        );
      case ToolCursorKind.text:
        final painter = TextPainter(
          text: TextSpan(
            text: 'I',
            style: TextStyle(
              color: ink,
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        painter.paint(canvas, position.translate(14, -12));
      case ToolCursorKind.candlestick:
        final body = Rect.fromCenter(
          center: position.translate(20, 18),
          width: 7,
          height: 10,
        );
        canvas.drawLine(
          Offset(body.center.dx, body.top - 5),
          Offset(body.center.dx, body.bottom + 5),
          Paint()
            ..color = ink
            ..strokeWidth = 1.4,
        );
        canvas.drawRect(body, Paint()..color = ink);
    }
  }

  void _paintDrawable(Canvas canvas, Drawable item) {
    switch (item) {
      case StrokeDrawable():
        final paint = Paint()
          ..color = item.color
          ..strokeWidth = item.width
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..style = PaintingStyle.stroke;
        if (item.points.isEmpty) return;
        if (item.points.length == 1) {
          canvas.drawCircle(
            item.points.first,
            item.width / 2,
            Paint()..color = item.color,
          );
          return;
        }
        final path = Path()..moveTo(item.points.first.dx, item.points.first.dy);
        for (final point in item.points.skip(1)) {
          path.lineTo(point.dx, point.dy);
        }
        canvas.drawPath(path, paint);
      case LineDrawable():
        final paint = Paint()
          ..color = item.color
          ..strokeWidth = item.width
          ..strokeCap = StrokeCap.round
          ..style = PaintingStyle.stroke;
        canvas.drawLine(item.start, item.end, paint);
      case RectangleDrawable():
        final paint = Paint()
          ..color = item.color
          ..strokeWidth = item.width
          ..style = item.filled ? PaintingStyle.fill : PaintingStyle.stroke;
        canvas.drawRect(item.rect, paint);
      case TextDrawable():
        final painter = TextPainter(
          text: TextSpan(
            text: item.text,
            style: TextStyle(
              color: item.color,
              fontSize: item.fontSize,
              fontWeight: FontWeight.w600,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        painter.paint(canvas, item.position);
      case CandleGroupDrawable():
        for (final candle in item.candles) {
          _paintCandleSpec(
            canvas,
            candle,
            item.strokeWidth,
            item.bullColor,
            item.bearColor,
          );
        }
    }
  }

  void _paintCandleSpec(
    Canvas canvas,
    CandleSpec candle,
    double strokeWidth,
    Color bullColor,
    Color bearColor,
  ) {
    final color = candle.closeY == candle.openY
        ? bullColor
        : (candle.isBullish ? bullColor : bearColor);
    final bodyTop = math.min(candle.openY, candle.closeY);
    final bodyBottom = math.max(candle.openY, candle.closeY);
    final bodyHeight = math.max(1.0, bodyBottom - bodyTop);
    final body = Rect.fromLTWH(candle.x, bodyTop, candle.width, bodyHeight);
    final midX = candle.x + candle.width / 2;
    final wick = Paint()
      ..color = color
      ..strokeWidth = math.max(1.0, strokeWidth)
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(midX, candle.highY), Offset(midX, bodyTop), wick);
    canvas.drawLine(Offset(midX, bodyBottom), Offset(midX, candle.lowY), wick);
    canvas.drawRect(body, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant AnnotationPainter oldDelegate) => true;
}

/// Bottom slide picker for the endless tile map.
///
/// Shows one chip per tile. Tap a number to jump exactly onto that tile
/// (clipped view showing only inside its borders).
/// Double-tap a name (or tap the pencil) to rename it.
/// Arrows move on the map: left/right/up/down. New tiles are created
/// endlessly in all four directions.
class _BoardSlideBar extends StatelessWidget {
  const _BoardSlideBar({
    required this.slides,
    required this.activeId,
    required this.onSelect,
    required this.onAdd,
    required this.onPrevious,
    required this.onNext,
    required this.onUp,
    required this.onDown,
    required this.onRename,
  });

  final List<BoardSlide> slides;
  final String? activeId;
  final ValueChanged<String> onSelect;
  final VoidCallback onAdd;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final VoidCallback onUp;
  final VoidCallback onDown;
  final ValueChanged<BoardSlide> onRename;

  @override
  Widget build(BuildContext context) {
    final activeIndex = indexOfBoardSlide(slides, activeId);
    return Material(
      key: const ValueKey('slide-bar'),
      color: const Color(0xff202735).withValues(alpha: .96),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 640),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              key: const ValueKey('slide-prev'),
              tooltip: 'Slide left',
              iconSize: 18,
              visualDensity: VisualDensity.compact,
              onPressed: onPrevious,
              icon: const Icon(Icons.chevron_left),
            ),
            IconButton(
              key: const ValueKey('slide-up'),
              tooltip: 'Slide up',
              iconSize: 18,
              visualDensity: VisualDensity.compact,
              onPressed: onUp,
              icon: const Icon(Icons.expand_less),
            ),
            IconButton(
              key: const ValueKey('slide-down'),
              tooltip: 'Slide down',
              iconSize: 18,
              visualDensity: VisualDensity.compact,
              onPressed: onDown,
              icon: const Icon(Icons.expand_more),
            ),
            Flexible(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (var i = 0; i < slides.length; i++)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 2),
                        child: GestureDetector(
                          onTap: () => onSelect(slides[i].id),
                          onDoubleTap: () => onRename(slides[i]),
                          child: Container(
                            key: ValueKey('slide-chip-$i'),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: slides[i].id == activeId
                                  ? const Color(0xff2d8ac7)
                                  : Colors.white.withValues(alpha: .08),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: slides[i].id == activeId
                                    ? Colors.white70
                                    : Colors.white24,
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Tooltip(
                                  message:
                                      'Go to slide ${slides[i].title} (double-tap to rename)',
                                  child: Text(
                                    slides[i].title,
                                    style: const TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                                if (slides[i].id == activeId)
                                  InkWell(
                                    key: ValueKey('slide-rename-$i'),
                                    borderRadius: BorderRadius.circular(6),
                                    onTap: () => onRename(slides[i]),
                                    child: const Padding(
                                      padding: EdgeInsets.only(left: 6),
                                      child: Icon(Icons.edit, size: 12),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            IconButton(
              key: const ValueKey('slide-next'),
              tooltip: 'Slide right',
              iconSize: 18,
              visualDensity: VisualDensity.compact,
              onPressed: onNext,
              icon: const Icon(Icons.chevron_right),
            ),
            IconButton(
              key: const ValueKey('slide-add'),
              tooltip: 'Add slide',
              iconSize: 18,
              visualDensity: VisualDensity.compact,
              onPressed: onAdd,
              icon: const Icon(Icons.add),
            ),
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: Text(
                '${activeIndex + 1}/${slides.length}',
                style: const TextStyle(
                  fontSize: 11,
                  color: Colors.white60,
                  fontFeatures: [],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({
    required this.dock,
    required this.mode,
    required this.slots,
    required this.activeSlotId,
    required this.paletteOpen,
    required this.quickColors,
    required this.expandedColors,
    required this.selectedColor,
    required this.magnifierZoom,
    required this.magnifierSize,
    required this.onDrag,
    required this.onDock,
    required this.onOverlayMenuOpen,
    required this.onOverlayMenuClose,
    required this.onPointer,
    required this.onMode,
    required this.onSlot,
    required this.onHand,
    required this.onEraser,
    required this.onMagnifier,
    required this.onMagnifierZoom,
    required this.onMagnifierSize,
    required this.onColor,
    required this.onTogglePalette,
    required this.onUndo,
    required this.onClear,
    required this.onScreenshot,
    required this.onSettings,
    required this.onAddSlot,
    required this.onHide,
    required this.onExit,
    required this.onChangeThickness,
    required this.onChangeFontSize,
    required this.onChangeFill,
  });

  final ToolbarDock dock;
  final CanvasMode mode;
  final List<ToolSlot> slots;
  final String? activeSlotId;
  final bool paletteOpen;
  final List<Color> quickColors;
  final bool expandedColors;
  final Color? selectedColor;
  final MagnifierZoom magnifierZoom;
  final MagnifierSize magnifierSize;
  final VoidCallback onDrag;
  final ValueChanged<ToolbarDock> onDock;
  final VoidCallback onOverlayMenuOpen;
  final VoidCallback onOverlayMenuClose;
  final VoidCallback onPointer;
  final ValueChanged<CanvasMode> onMode;
  final ValueChanged<ToolSlot> onSlot;
  final VoidCallback onHand;
  final VoidCallback onEraser;
  final VoidCallback onMagnifier;
  final ValueChanged<MagnifierZoom> onMagnifierZoom;
  final ValueChanged<MagnifierSize> onMagnifierSize;
  final ValueChanged<Color> onColor;
  final VoidCallback onTogglePalette;
  final VoidCallback onUndo;
  final VoidCallback onClear;
  final VoidCallback onScreenshot;
  final VoidCallback onSettings;
  final VoidCallback onAddSlot;
  final VoidCallback onHide;
  final VoidCallback onExit;
  final ValueChanged<double> onChangeThickness;
  final ValueChanged<double> onChangeFontSize;
  final ValueChanged<bool> onChangeFill;

  BorderRadius get _radius => switch (dock) {
    ToolbarDock.left => const BorderRadius.horizontal(
      right: Radius.circular(14),
    ),
    ToolbarDock.right => const BorderRadius.horizontal(
      left: Radius.circular(14),
    ),
    ToolbarDock.top => const BorderRadius.vertical(bottom: Radius.circular(14)),
    ToolbarDock.bottom => const BorderRadius.vertical(top: Radius.circular(14)),
  };

  Widget _modeIcon(CanvasMode item) => switch (item) {
    CanvasMode.screen => const Icon(Icons.desktop_windows_outlined, size: 18),
    CanvasMode.whiteboard => const _BoardModeIcon(whiteboard: true),
    CanvasMode.blackboard => const _BoardModeIcon(whiteboard: false),
  };

  @override
  Widget build(BuildContext context) {
    ToolSlot? selectedSlot;
    for (final slot in slots) {
      if (slot.id == activeSlotId) {
        selectedSlot = slot;
        break;
      }
    }
    final vertical = dock.isVertical;
    final children = <Widget>[
      _ToolbarDragHandle(
        onDrag: onDrag,
        dock: dock,
        onDock: onDock,
        onOverlayMenuOpen: onOverlayMenuOpen,
        onOverlayMenuClose: onOverlayMenuClose,
      ),
      _ToolIcon(
        icon: Icons.mouse_outlined,
        label: 'Pointer / desktop (Ctrl+Shift+P)',
        selected: activeSlotId == kPointerSlotId,
        onPressed: onPointer,
        compact: true,
      ),
      const Divider(height: 10, color: Colors.white24),
      for (final item in CanvasMode.values)
        _ToolIcon(
          iconWidget: _modeIcon(item),
          label: item.label,
          selected: mode == item,
          onPressed: () => onMode(item),
          compact: true,
        ),
      const Divider(height: 10, color: Colors.white24),
      for (final slot in slots)
        Padding(
          padding: EdgeInsets.only(
            bottom: vertical ? 2 : 0,
            right: vertical ? 0 : 2,
          ),
          child: _ToolIcon(
            buttonKey: ValueKey('tool-${slot.id}'),
            icon: slot.type.icon,
            iconWidget: slot.type.icon == null
                ? ColorFiltered(
                    colorFilter: ColorFilter.mode(
                      slot.color,
                      BlendMode.srcATop,
                    ),
                    child: slot.type.toolbarIcon,
                  )
                : null,
            label: slot.placedPresetText != null
                ? '${slot.placedPresetText} (click board to place)'
                : slot.type == ToolType.line
                ? 'Line (toggle • hold Shift for horizontal/vertical)'
                : slot.type == ToolType.candlestick
                ? '${slot.toolbarTitle ?? slot.type.label} '
                      '(drag body, then wicks)'
                : '${slot.type.label} (toggle)',
            selected: slot.id == activeSlotId,
            color: slot.color,
            onPressed: () => onSlot(slot),
            badge: slot.toolbarBadge,
          ),
        ),
      if (selectedSlot != null)
        _SlotControls(
          slot: selectedSlot,
          horizontal: !vertical,
          onChangeThickness: onChangeThickness,
          onChangeFontSize: onChangeFontSize,
          onChangeFill: onChangeFill,
        ),
      _ToolIcon(
        icon: Icons.add_circle_outline,
        label: 'Add tool slot',
        onPressed: onAddSlot,
        compact: true,
      ),
      const Divider(height: 10, color: Colors.white24),
      _ToolIcon(
        buttonKey: const ValueKey('tool-hand'),
        icon: Icons.pan_tool_outlined,
        label: 'Hand (drag to move the board)',
        selected: activeSlotId == kHandSlotId,
        onPressed: onHand,
      ),
      _ToolIcon(
        iconWidget: const _EraserIcon(),
        label: 'Eraser (click or drag over objects)',
        selected: activeSlotId == '__eraser__',
        onPressed: onEraser,
      ),
      _ToolIcon(
        iconWidget: const _MagnifierIcon(),
        label: 'Magnifier',
        selected: activeSlotId == '__magnifier__',
        onPressed: onMagnifier,
      ),
      if (activeSlotId == '__magnifier__')
        _MagnifierControls(
          zoom: magnifierZoom,
          size: magnifierSize,
          horizontal: !vertical,
          onZoom: onMagnifierZoom,
          onSize: onMagnifierSize,
        ),
      _ToolIcon(
        icon: Icons.undo,
        label: 'Undo',
        onPressed: onUndo,
        compact: true,
      ),
      _ToolIcon(
        icon: Icons.delete_outline,
        label: mode == CanvasMode.screen
            ? 'Trash current canvas'
            : 'Trash current slide',
        onPressed: onClear,
        compact: true,
      ),
      _ToolIcon(
        icon: Icons.camera_alt_outlined,
        label: 'Screenshot',
        onPressed: onScreenshot,
        compact: true,
      ),
      const Divider(height: 10, color: Colors.white24),
      _ToolIcon(
        icon: Icons.palette_outlined,
        label: selectedSlot == null
            ? 'Select a drawing tool to change color'
            : 'Colors',
        selected: paletteOpen,
        enabled: selectedSlot != null,
        onPressed: onTogglePalette,
        compact: true,
      ),
      if ((paletteOpen || expandedColors) && selectedSlot != null)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: _QuickPalette(
            colors: quickColors,
            selectedColor: selectedColor,
            onColor: onColor,
          ),
        ),
      const SizedBox(height: 2),
      _ToolIcon(
        icon: Icons.tune,
        buttonKey: const ValueKey('settings-button'),
        label: 'Settings (version $kAppVersion)',
        onPressed: onSettings,
        compact: true,
      ),
      _ToolIcon(
        icon: switch (dock) {
          ToolbarDock.left => Icons.chevron_left,
          ToolbarDock.right => Icons.chevron_right,
          ToolbarDock.top => Icons.expand_less,
          ToolbarDock.bottom => Icons.expand_more,
        },
        label: 'Hide toolbar',
        onPressed: onHide,
        compact: true,
      ),
      _ToolIcon(
        icon: Icons.power_settings_new,
        label: 'Exit Screen pen by Hamed Mosaddeghian (Ctrl+Shift+Q)',
        color: const Color(0xffff7082),
        onPressed: onExit,
        compact: true,
      ),
    ];

    return Material(
      color: Colors.transparent,
      child: Container(
        width: vertical ? kToolbarThickness : null,
        height: vertical ? null : kToolbarThickness,
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
        decoration: BoxDecoration(
          color: const Color(0xff202735).withValues(alpha: .96),
          borderRadius: _radius,
          boxShadow: const [
            BoxShadow(
              color: Colors.black54,
              blurRadius: 18,
              offset: Offset(2, 3),
            ),
          ],
        ),
        child: SingleChildScrollView(
          scrollDirection: vertical ? Axis.vertical : Axis.horizontal,
          child: vertical
              ? Column(mainAxisSize: MainAxisSize.min, children: children)
              : Row(mainAxisSize: MainAxisSize.min, children: children),
        ),
      ),
    );
  }
}

class _BoardModeIcon extends StatelessWidget {
  const _BoardModeIcon({required this.whiteboard});

  final bool whiteboard;

  @override
  Widget build(BuildContext context) => CustomPaint(
    size: const Size(20, 20),
    painter: _BoardModeIconPainter(whiteboard: whiteboard),
  );
}

class _BoardModeIconPainter extends CustomPainter {
  const _BoardModeIconPainter({required this.whiteboard});

  final bool whiteboard;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = RRect.fromRectAndRadius(
      Rect.fromLTWH(1.5, 2.5, size.width - 3, size.height - 5),
      const Radius.circular(2.5),
    );
    canvas.drawRRect(
      rect,
      Paint()..color = whiteboard ? Colors.white : const Color(0xff1a1f2a),
    );
    canvas.drawRRect(
      rect,
      Paint()
        ..color = whiteboard ? const Color(0xff9aa3b2) : const Color(0xff6dc5ff)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4,
    );
    final chalk = Paint()
      ..color = whiteboard ? const Color(0xff35a7ff) : const Color(0xffffd447)
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(
      Offset(size.width * .28, size.height * .42),
      Offset(size.width * .72, size.height * .38),
      chalk,
    );
    canvas.drawLine(
      Offset(size.width * .32, size.height * .62),
      Offset(size.width * .68, size.height * .58),
      chalk,
    );
  }

  @override
  bool shouldRepaint(covariant _BoardModeIconPainter oldDelegate) =>
      oldDelegate.whiteboard != whiteboard;
}

class _ToolbarDragHandle extends StatelessWidget {
  const _ToolbarDragHandle({
    required this.onDrag,
    required this.dock,
    required this.onDock,
    required this.onOverlayMenuOpen,
    required this.onOverlayMenuClose,
  });

  final VoidCallback onDrag;
  final ToolbarDock dock;
  final ValueChanged<ToolbarDock> onDock;
  final VoidCallback onOverlayMenuOpen;
  final VoidCallback onOverlayMenuClose;

  @override
  Widget build(BuildContext context) => PopupMenuButton<ToolbarDock>(
    tooltip: 'Dock toolbar • drag to move display',
    initialValue: dock,
    onOpened: onOverlayMenuOpen,
    onSelected: (side) {
      onDock(side);
      onOverlayMenuClose();
    },
    onCanceled: onOverlayMenuClose,
    itemBuilder: (context) => [
      for (final side in ToolbarDock.values)
        PopupMenuItem(
          value: side,
          child: Row(
            children: [
              Icon(side.icon, size: 18),
              const SizedBox(width: 10),
              Text('Dock ${side.label}'),
              const Spacer(),
              if (side == dock) const Icon(Icons.check, size: 16),
            ],
          ),
        ),
    ],
    child: MouseRegion(
      cursor: SystemMouseCursors.move,
      child: GestureDetector(
        key: const ValueKey('toolbar-drag-handle'),
        behavior: HitTestBehavior.opaque,
        onPanStart: (_) => onDrag(),
        child: SizedBox(
          width: dock.isVertical ? 44 : 26,
          height: dock.isVertical ? 20 : 44,
          child: Icon(
            dock.isVertical ? Icons.drag_indicator : Icons.drag_handle,
            size: 18,
            color: Colors.white54,
          ),
        ),
      ),
    ),
  );
}

class _EraserIcon extends StatelessWidget {
  const _EraserIcon();

  @override
  Widget build(BuildContext context) =>
      const CustomPaint(size: Size(22, 22), painter: _EraserIconPainter());
}

class _EraserIconPainter extends CustomPainter {
  const _EraserIconPainter();

  @override
  void paint(Canvas canvas, Size size) {
    canvas
      ..save()
      ..translate(size.width / 2, size.height / 2)
      ..rotate(-.62);
    final body = RRect.fromRectAndRadius(
      const Rect.fromLTWH(-9, -5, 18, 10),
      const Radius.circular(2.5),
    );
    canvas.drawRRect(body, Paint()..color = const Color(0xffe9edf5));
    canvas.drawRect(
      const Rect.fromLTWH(-9, -5, 8, 10),
      Paint()..color = const Color(0xffff7082),
    );
    canvas.drawRRect(
      body,
      Paint()
        ..color = Colors.white70
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
    canvas.drawLine(
      const Offset(-1, -5),
      const Offset(-1, 5),
      Paint()
        ..color = const Color(0xff6f7787)
        ..strokeWidth = 1,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _EraserIconPainter oldDelegate) => false;
}

class _HighlighterIcon extends StatelessWidget {
  const _HighlighterIcon();

  @override
  Widget build(BuildContext context) =>
      const CustomPaint(size: Size(22, 22), painter: _HighlighterIconPainter());
}

class _HighlighterIconPainter extends CustomPainter {
  const _HighlighterIconPainter();

  @override
  void paint(Canvas canvas, Size size) {
    canvas
      ..save()
      ..translate(size.width / 2, size.height / 2)
      ..rotate(-.55);
    final body = RRect.fromRectAndRadius(
      const Rect.fromLTWH(-3.5, -9, 7, 14),
      const Radius.circular(1.5),
    );
    canvas.drawRRect(body, Paint()..color = const Color(0xffffd447));
    canvas.drawRRect(
      body,
      Paint()
        ..color = Colors.white70
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
    final tip = Path()
      ..moveTo(-3.5, 5)
      ..lineTo(3.5, 5)
      ..lineTo(2.2, 9)
      ..lineTo(-2.2, 9)
      ..close();
    canvas.drawPath(tip, Paint()..color = const Color(0xffffc107));
    canvas.drawRect(
      const Rect.fromLTWH(-4.5, 8.5, 9, 2.5),
      Paint()..color = const Color(0xffffd447).withValues(alpha: .55),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _HighlighterIconPainter oldDelegate) => false;
}

class _CandlestickIcon extends StatelessWidget {
  const _CandlestickIcon();

  @override
  Widget build(BuildContext context) =>
      const CustomPaint(size: Size(22, 22), painter: _CandlestickIconPainter());
}

class _CandlestickIconPainter extends CustomPainter {
  const _CandlestickIconPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final midX = size.width / 2;
    final body = Rect.fromCenter(
      center: Offset(midX, size.height / 2),
      width: 7,
      height: 10,
    );
    final wick = Paint()
      ..color = const Color(0xff46d17d)
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(midX, 2), Offset(midX, body.top), wick);
    canvas.drawLine(
      Offset(midX, body.bottom),
      Offset(midX, size.height - 2),
      wick,
    );
    canvas.drawRect(body, Paint()..color = const Color(0xff46d17d));
  }

  @override
  bool shouldRepaint(covariant _CandlestickIconPainter oldDelegate) => false;
}

class _MagnifierIcon extends StatelessWidget {
  const _MagnifierIcon();

  @override
  Widget build(BuildContext context) =>
      const CustomPaint(size: Size(22, 22), painter: _MagnifierIconPainter());
}

class _MagnifierIconPainter extends CustomPainter {
  const _MagnifierIconPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final glass = Rect.fromLTWH(2, 2, 12, 10);
    canvas.drawRRect(
      RRect.fromRectAndRadius(glass, const Radius.circular(2)),
      Paint()..color = const Color(0xff6dc5ff).withValues(alpha: .25),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(glass, const Radius.circular(2)),
      Paint()
        ..color = const Color(0xff9ad8ff)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
    canvas.drawLine(
      const Offset(13.5, 11.5),
      const Offset(19, 18),
      Paint()
        ..color = const Color(0xffc5cedd)
        ..strokeWidth = 2.2
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(covariant _MagnifierIconPainter oldDelegate) => false;
}

class _MagnifierControls extends StatelessWidget {
  const _MagnifierControls({
    required this.zoom,
    required this.size,
    required this.onZoom,
    required this.onSize,
    this.horizontal = false,
  });

  final MagnifierZoom zoom;
  final MagnifierSize size;
  final ValueChanged<MagnifierZoom> onZoom;
  final ValueChanged<MagnifierSize> onSize;
  final bool horizontal;

  @override
  Widget build(BuildContext context) {
    final zoomRow = Wrap(
      spacing: 2,
      runSpacing: 2,
      alignment: WrapAlignment.center,
      children: [
        for (final option in MagnifierZoom.values)
          _MiniChip(
            key: ValueKey('magnifier-zoom-${option.name}'),
            label: option.label,
            selected: option == zoom,
            onTap: () => onZoom(option),
          ),
      ],
    );
    final sizeRow = Wrap(
      spacing: 2,
      runSpacing: 2,
      alignment: WrapAlignment.center,
      children: [
        for (final option in MagnifierSize.values)
          _MiniChip(
            key: ValueKey('magnifier-size-${option.name}'),
            label: option.label,
            selected: option == size,
            onTap: () => onSize(option),
          ),
      ],
    );
    if (horizontal) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [zoomRow, const SizedBox(width: 8), sizeRow],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 2),
      child: Column(children: [zoomRow, const SizedBox(height: 4), sizeRow]),
    );
  }
}

class _MiniChip extends StatelessWidget {
  const _MiniChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: selected ? const Color(0xff2d8ac7) : const Color(0xff2a3344),
    borderRadius: BorderRadius.circular(6),
    child: InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        child: Text(
          label,
          style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w600),
        ),
      ),
    ),
  );
}

class _ToolIcon extends StatelessWidget {
  const _ToolIcon({
    required this.label,
    required this.onPressed,
    this.icon,
    this.iconWidget,
    this.buttonKey,
    this.selected = false,
    this.color,
    this.compact = false,
    this.badge,
    this.enabled = true,
  }) : assert(icon != null || iconWidget != null);

  final IconData? icon;
  final Widget? iconWidget;
  final Key? buttonKey;
  final String label;
  final VoidCallback onPressed;
  final bool selected;
  final Color? color;
  final bool compact;
  final String? badge;
  final bool enabled;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: selected,
    enabled: enabled,
    label: label,
    child: Tooltip(
      message: label,
      child: Opacity(
        opacity: enabled ? 1 : .38,
        child: SizedBox(
          key: buttonKey,
          width: 44,
          height: compact ? 32 : 36,
          child: Material(
            color: selected ? const Color(0xff2d8ac7) : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: enabled ? onPressed : null,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  iconWidget ??
                      Icon(
                        icon,
                        size: compact ? 18 : 20,
                        color: color ?? Colors.white.withValues(alpha: .9),
                        shadows:
                            color != null && color!.computeLuminance() < .18
                            ? const [
                                Shadow(color: Colors.white70, blurRadius: 2),
                              ]
                            : null,
                      ),
                  if (badge != null)
                    Positioned(
                      right: 5,
                      bottom: 2,
                      child: Text(
                        badge!,
                        style: const TextStyle(
                          fontSize: 8,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class _SlotControls extends StatelessWidget {
  const _SlotControls({
    required this.slot,
    required this.onChangeThickness,
    required this.onChangeFontSize,
    required this.onChangeFill,
    this.horizontal = false,
  });

  final ToolSlot slot;
  final ValueChanged<double> onChangeThickness;
  final ValueChanged<double> onChangeFontSize;
  final ValueChanged<bool> onChangeFill;
  final bool horizontal;

  @override
  Widget build(BuildContext context) {
    final controls = <Widget>[
      Container(
        height: 5,
        width: 32,
        decoration: BoxDecoration(
          color: slot.color,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.white38),
        ),
      ),
      if (slot.type == ToolType.text)
        _FontSizeSelector(value: slot.fontSize, onChanged: onChangeFontSize)
      else
        _WidthSelector(value: slot.thickness, onChanged: onChangeThickness),
      if (slot.type == ToolType.rectangle)
        Tooltip(
          message: slot.filled ? 'Filled rectangle' : 'Outline rectangle',
          child: IconButton(
            key: const ValueKey('rectangle-fill-toggle'),
            visualDensity: VisualDensity.compact,
            style: IconButton.styleFrom(
              backgroundColor: slot.filled
                  ? const Color(0xff2d8ac7)
                  : Colors.transparent,
            ),
            onPressed: () => onChangeFill(!slot.filled),
            icon: const Icon(Icons.format_color_fill_outlined, size: 18),
          ),
        ),
    ];
    if (horizontal) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < controls.length; i++) ...[
              if (i > 0) const SizedBox(width: 6),
              controls[i],
            ],
          ],
        ),
      );
    }
    return Column(
      children: [
        const SizedBox(height: 6),
        for (var i = 0; i < controls.length; i++) ...[
          if (i > 0) const SizedBox(height: 4),
          controls[i],
        ],
      ],
    );
  }
}

class _WidthSelector extends StatelessWidget {
  const _WidthSelector({required this.value, required this.onChanged});

  final double value;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final roundedValue = value.round();
    return PopupMenuButton<double>(
      key: const ValueKey('width-selector'),
      tooltip: 'Stroke width: $roundedValue px',
      initialValue: toolWidthOptions.contains(value) ? value : null,
      onSelected: onChanged,
      itemBuilder: (context) => [
        for (final width in toolWidthOptions)
          PopupMenuItem<double>(
            value: width,
            child: Row(
              children: [
                SizedBox(
                  width: 62,
                  child: Container(
                    height: width.clamp(2, 8).toDouble(),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primary,
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Text('${width.round()} px'),
                const Spacer(),
                if ((value - width).abs() < .01)
                  const Icon(Icons.check, size: 18),
              ],
            ),
          ),
      ],
      child: Container(
        key: ValueKey('active-width-$roundedValue'),
        width: 46,
        height: 31,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: .06),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.white24),
        ),
        child: Text(
          '$roundedValue px',
          style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}

class _FontSizeSelector extends StatelessWidget {
  const _FontSizeSelector({required this.value, required this.onChanged});

  static const sizes = <double>[18, 24, 32, 48, 64];

  final double value;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) => PopupMenuButton<double>(
    key: const ValueKey('font-size-selector'),
    tooltip: 'Text size: ${value.round()} px',
    initialValue: sizes.contains(value) ? value : null,
    onSelected: onChanged,
    itemBuilder: (context) => [
      for (final size in sizes)
        PopupMenuItem<double>(
          value: size,
          child: Row(
            children: [
              Text('${size.round()} px'),
              const Spacer(),
              if ((value - size).abs() < .01) const Icon(Icons.check, size: 18),
            ],
          ),
        ),
    ],
    child: Container(
      width: 46,
      height: 31,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: .06),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white24),
      ),
      child: Text(
        'T ${value.round()}',
        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
      ),
    ),
  );
}

class _QuickPalette extends StatelessWidget {
  const _QuickPalette({
    required this.colors,
    required this.selectedColor,
    required this.onColor,
  });

  final List<Color> colors;
  final Color? selectedColor;
  final ValueChanged<Color> onColor;

  static const double _swatchSize = 22;
  static const double _spacing = 4;
  static const int _columns = 2;

  @override
  Widget build(BuildContext context) {
    // Fixed 2×N square grid (not a single horizontal row), matching the
    // compact vertical-dock palette. Width is capped so Wrap always wraps.
    final gridWidth = _columns * _swatchSize + (_columns - 1) * _spacing;
    return SizedBox(
      key: const ValueKey('quick-color-palette'),
      width: gridWidth,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Wrap(
            spacing: _spacing,
            runSpacing: _spacing,
            alignment: WrapAlignment.start,
            children: [
              for (final color in colors)
                _PaletteSwatch(
                  color: color,
                  selected: _sameRgb(color, selectedColor),
                  size: _swatchSize,
                  onPressed: () => onColor(color),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Tooltip(
            message: 'Full color palette',
            child: InkWell(
              borderRadius: BorderRadius.circular(6),
              onTap: () async {
                final picked = await showDialog<Color>(
                  context: context,
                  builder: (context) => _ColorDialog(
                    initialColor: selectedColor ?? const Color(0xff35a7ff),
                  ),
                );
                if (picked != null) onColor(picked);
              },
              child: Container(
                width: gridWidth,
                height: 24,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.white38),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Text('More', style: TextStyle(fontSize: 10)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

bool _sameRgb(Color color, Color? other) =>
    other != null &&
    (color.toARGB32() & 0x00ffffff) == (other.toARGB32() & 0x00ffffff);

Color _contrastFor(Color color) =>
    color.computeLuminance() > .48 ? Colors.black : Colors.white;

String _colorHex(Color color) =>
    '#${(color.toARGB32() & 0x00ffffff).toRadixString(16).padLeft(6, '0').toUpperCase()}';

class _PaletteSwatch extends StatelessWidget {
  const _PaletteSwatch({
    required this.color,
    required this.selected,
    required this.onPressed,
    this.size = 38,
  });

  final Color color;
  final bool selected;
  final VoidCallback onPressed;
  final double size;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: selected,
    label: 'Color ${_colorHex(color)}',
    child: Tooltip(
      message: _colorHex(color),
      child: InkWell(
        borderRadius: BorderRadius.circular(7),
        onTap: onPressed,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(7),
            border: Border.all(
              color: selected ? _contrastFor(color) : Colors.white38,
              width: selected ? 3 : 1,
            ),
            boxShadow: selected
                ? const [BoxShadow(color: Colors.black45, blurRadius: 4)]
                : null,
          ),
          child: selected
              ? Icon(Icons.check, size: size * .55, color: _contrastFor(color))
              : null,
        ),
      ),
    ),
  );
}

class _ColorDialog extends StatefulWidget {
  const _ColorDialog({required this.initialColor});

  final Color initialColor;

  @override
  State<_ColorDialog> createState() => _ColorDialogState();
}

class _ColorDialogState extends State<_ColorDialog> {
  late Color _color;

  int get _red => (_color.r * 255).round();
  int get _green => (_color.g * 255).round();
  int get _blue => (_color.b * 255).round();

  @override
  void initState() {
    super.initState();
    _color = widget.initialColor.withValues(alpha: 1);
  }

  void _setChannels({int? red, int? green, int? blue}) {
    setState(
      () => _color = Color.fromARGB(
        255,
        red ?? _red,
        green ?? _green,
        blue ?? _blue,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Full color palette'),
    content: SizedBox(
      width: 320,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.center,
            children: [
              for (final color in annotationColors)
                _PaletteSwatch(
                  color: color,
                  selected: _sameRgb(color, _color),
                  onPressed: () => setState(() => _color = color),
                ),
            ],
          ),
          const SizedBox(height: 14),
          _ColorChannelSlider(
            label: 'R',
            color: const Color(0xffff5d73),
            value: _red,
            onChanged: (value) => _setChannels(red: value),
          ),
          _ColorChannelSlider(
            label: 'G',
            color: const Color(0xff56d364),
            value: _green,
            onChanged: (value) => _setChannels(green: value),
          ),
          _ColorChannelSlider(
            label: 'B',
            color: const Color(0xff35a7ff),
            value: _blue,
            onChanged: (value) => _setChannels(blue: value),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: _color,
                  borderRadius: BorderRadius.circular(7),
                  border: Border.all(color: Colors.white54),
                ),
              ),
              const SizedBox(width: 10),
              Text(
                _colorHex(_color),
                style: const TextStyle(
                  fontFeatures: [ui.FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, _color),
        child: const Text('Use color'),
      ),
    ],
  );
}

class _ColorChannelSlider extends StatelessWidget {
  const _ColorChannelSlider({
    required this.label,
    required this.color,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final Color color;
  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      SizedBox(
        width: 18,
        child: Text(label, style: TextStyle(color: color)),
      ),
      Expanded(
        child: Slider(
          value: value.toDouble(),
          min: 0,
          max: 255,
          activeColor: color,
          onChanged: (next) => onChanged(next.round()),
        ),
      ),
      SizedBox(
        width: 30,
        child: Text(
          '$value',
          textAlign: TextAlign.right,
          style: const TextStyle(fontSize: 11),
        ),
      ),
    ],
  );
}

class _SettingSectionTitle extends StatelessWidget {
  const _SettingSectionTitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 8, bottom: 4),
    child: Text(
      text.toUpperCase(),
      style: TextStyle(
        color: Theme.of(context).colorScheme.primary,
        fontSize: 12,
        fontWeight: FontWeight.bold,
        letterSpacing: 1.2,
      ),
    ),
  );
}

class _AddSlotDialog extends StatefulWidget {
  const _AddSlotDialog();

  @override
  State<_AddSlotDialog> createState() => _AddSlotDialogState();
}

class _AddSlotDialogState extends State<_AddSlotDialog> {
  ToolType _type = ToolType.rectangle;
  Color _color = const Color(0xff35a7ff);
  double _thickness = 4;
  double _fontSize = 24;
  bool _filled = false;

  void _selectType(ToolType type) {
    setState(() {
      _type = type;
      if (type == ToolType.highlighter) {
        _thickness = 20;
        _color = const Color(0xffffd447);
      } else if (type == ToolType.text) {
        _fontSize = 24;
      } else if (type == ToolType.candlestick) {
        _thickness = 8;
        _color = const Color(0xff46d17d);
      } else {
        _thickness = 4;
      }
    });
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Add tool slot'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        DropdownButtonFormField<ToolType>(
          initialValue: _type,
          decoration: const InputDecoration(labelText: 'Tool type'),
          items: [
            for (final type in ToolType.values)
              DropdownMenuItem(value: type, child: Text(type.label)),
          ],
          onChanged: (value) {
            if (value != null) _selectType(value);
          },
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            const Text('Color'),
            const SizedBox(width: 16),
            for (final color in [
              const Color(0xff35a7ff),
              const Color(0xffff5d73),
              const Color(0xff56d364),
              const Color(0xffffd447),
            ])
              GestureDetector(
                onTap: () => setState(() => _color = color),
                child: Container(
                  margin: const EdgeInsets.only(right: 8),
                  width: 26,
                  height: 26,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: _color == color
                          ? Colors.white
                          : Colors.transparent,
                      width: 2,
                    ),
                  ),
                ),
              ),
          ],
        ),
        if (_type == ToolType.text)
          Row(
            children: [
              const Text('Text size'),
              Expanded(
                child: Slider(
                  value: _fontSize,
                  min: 12,
                  max: 72,
                  divisions: 20,
                  label: '${_fontSize.round()} px',
                  onChanged: (value) => setState(() => _fontSize = value),
                ),
              ),
            ],
          )
        else
          Row(
            children: [
              const Text('Thickness'),
              Expanded(
                child: Slider(
                  value: _thickness,
                  min: 1,
                  max: 24,
                  divisions: 23,
                  label: '${_thickness.round()} px',
                  onChanged: (value) => setState(() => _thickness = value),
                ),
              ),
            ],
          ),
        if (_type == ToolType.rectangle)
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Filled'),
            value: _filled,
            onChanged: (value) => setState(() => _filled = value ?? false),
          ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(
          context,
          ToolSlot(
            id: 'new',
            type: _type,
            color: _color,
            thickness: _thickness,
            filled: _filled,
            fontSize: _fontSize,
          ),
        ),
        child: const Text('Add'),
      ),
    ],
  );
}
