import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pen/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('highlighter keeps an opaque selection color and translucent ink', () {
    final slot = ToolSlot(
      id: 'highlighter-test',
      type: ToolType.highlighter,
      color: const Color(0xffffd447),
      thickness: 20,
    );

    expect(slot.color.a, 1);
    expect(slot.drawingColor.a, closeTo(highlighterOpacity, .001));
    expect(
      slot.drawingColor.toARGB32() & 0x00ffffff,
      slot.color.toARGB32() & 0x00ffffff,
    );

    final restored = ToolSlot.fromJson(slot.toJson());
    expect(restored.type, ToolType.highlighter);
    expect(restored.thickness, 20);
    expect(restored.drawingColor.a, closeTo(highlighterOpacity, .001));
  });

  test('toolbar thickness constant sits between the prior extremes', () {
    expect(kToolbarThickness, lessThan(60));
    expect(kToolbarThickness, greaterThan(52));
    expect(kToolbarThickness, 56);
  });

  test('pointer slot id is distinct from idle desktop null', () {
    expect(kPointerSlotId, '__pointer__');
  });

  test('line axis constraint follows the dominant drag direction', () {
    expect(
      constrainLineToAxis(const Offset(10, 20), const Offset(80, 50)),
      const Offset(80, 20),
    );
    expect(
      constrainLineToAxis(const Offset(10, 20), const Offset(30, 100)),
      const Offset(10, 100),
    );
  });

  test('magnifier zoom and size options match product requirements', () {
    expect(MagnifierZoom.values.map((z) => z.factor), [2, 4, 8]);
    expect(MagnifierSize.values, hasLength(3));
    expect(
      MagnifierSize.small.lensSize.width,
      lessThan(MagnifierSize.medium.lensSize.width),
    );
    expect(
      MagnifierSize.medium.lensSize.width,
      lessThan(MagnifierSize.large.lensSize.width),
    );
  });

  test('cover-taskbar overlay bounds expand to full monitor edges', () {
    final bounds = overlayBoundsForDisplay(
      workOrigin: const Offset(0, 0),
      workSize: const Size(1920, 1040),
      displaySize: const Size(1920, 1080),
      coverTaskbar: true,
    );
    expect(bounds.left, 0);
    expect(bounds.top, 0);
    expect(bounds.width, 1920);
    expect(bounds.height, 1080);
  });

  testWidgets('empty prefs yield one pen and one highlighter', (tester) async {
    SharedPreferences.setMockInitialValues({});

    await tester.pumpWidget(const PenApp());
    await tester.pumpAndSettle();

    expect(find.byTooltip('Pen (toggle)'), findsOneWidget);
    expect(find.byTooltip('Highlighter (toggle)'), findsOneWidget);
  });

  testWidgets('migrates legacy two-pen tool_slots to pen plus highlighter', (
    tester,
  ) async {
    final penA = ToolSlot(
      id: 'pen-a',
      type: ToolType.pen,
      color: const Color(0xff35a7ff),
      thickness: 4,
    );
    final penB = ToolSlot(
      id: 'pen-b',
      type: ToolType.pen,
      color: const Color(0xffff5d73),
      thickness: 8,
    );
    SharedPreferences.setMockInitialValues({
      'tool_slots': [jsonEncode(penA.toJson()), jsonEncode(penB.toJson())],
    });

    await tester.pumpWidget(const PenApp());
    await tester.pumpAndSettle();

    expect(find.byTooltip('Pen (toggle)'), findsOneWidget);
    expect(find.byTooltip('Highlighter (toggle)'), findsOneWidget);
  });

  testWidgets('renders one pen, a highlighter, pointer mode, and exit', (
    tester,
  ) async {
    await tester.pumpWidget(const PenApp());
    await tester.pumpAndSettle();

    expect(find.byType(PenApp), findsOneWidget);
    expect(find.byTooltip('Pen (toggle)'), findsOneWidget);
    expect(find.byTooltip('Highlighter (toggle)'), findsOneWidget);
    expect(find.byTooltip('Pointer / desktop (Ctrl+Shift+P)'), findsOneWidget);
    expect(find.byTooltip('Magnifier'), findsOneWidget);
    expect(find.byTooltip('Exit Screen pen by Hamed Mosaddeghian (Ctrl+Shift+Q)'), findsOneWidget);
  });

  testWidgets('pointer tool button shows the presentation ring', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const PenApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Pointer / desktop (Ctrl+Shift+P)'));
    await tester.pumpAndSettle();

    final painter = _annotationPainter(tester);
    expect(painter.showPointer, isTrue);
  });

  testWidgets('magnifier exposes zoom and size chips when active', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const PenApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Magnifier'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('magnifier-zoom-x2')), findsOneWidget);
    expect(find.byKey(const ValueKey('magnifier-zoom-x4')), findsOneWidget);
    expect(find.byKey(const ValueKey('magnifier-zoom-x8')), findsOneWidget);
    expect(find.byKey(const ValueKey('magnifier-size-small')), findsOneWidget);
    expect(find.byKey(const ValueKey('magnifier-size-medium')), findsOneWidget);
    expect(find.byKey(const ValueKey('magnifier-size-large')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('magnifier-zoom-x4')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('magnifier-size-large')));
    await tester.pumpAndSettle();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('magnifier_zoom'), 'x4');
    expect(prefs.getString('magnifier_size'), 'large');
  });

  testWidgets('selected width is reflected in UI and committed stroke', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const PenApp());
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byKey(const ValueKey('width-selector')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('active-width-4')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('width-selector')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('8 px').last);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('active-width-8')), findsOneWidget);
    await tester.timedDragFrom(
      const Offset(360, 220),
      const Offset(90, 45),
      const Duration(milliseconds: 150),
    );
    await tester.pumpAndSettle();

    final painter = _annotationPainter(tester);
    expect(painter.drawables, hasLength(1));
    final stroke = painter.drawables.single as StrokeDrawable;
    expect(stroke.width, 8);
    expect(stroke.color.a, 1);
  });

  testWidgets('holding Shift locks the line tool to the nearest axis', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const PenApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('tool-line-a')));
    await tester.pumpAndSettle();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);

    await tester.timedDragFrom(
      const Offset(380, 260),
      const Offset(-280, 60),
      const Duration(milliseconds: 100),
    );
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();

    final line = _annotationPainter(tester).drawables.single as LineDrawable;
    expect(line.start.dy, line.end.dy);
    expect(line.start.dx, isNot(line.end.dx));
  });

  testWidgets('Shift pressed after a line drag starts still locks the axis', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const PenApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('tool-line-a')));
    await tester.pumpAndSettle();

    final gesture = await tester.startGesture(const Offset(380, 260));
    await tester.pump();
    await gesture.moveBy(const Offset(-80, 40));
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump(const Duration(milliseconds: 20));
    await gesture.moveBy(const Offset(-200, 20));
    await tester.pump();
    await gesture.up();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();

    final line = _annotationPainter(tester).drawables.single as LineDrawable;
    expect(line.start.dy, line.end.dy);
    expect(line.start.dx, isNot(line.end.dx));
  });

  testWidgets('settings shows the Screen pen by Hamed Mosaddeghian version', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const PenApp());
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byKey(const ValueKey('settings-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.byKey(const ValueKey('app-version')), findsOneWidget);
    expect(find.text('Version $kAppVersion'), findsOneWidget);
  });

  testWidgets('highlighter selection commits translucent wide strokes', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const PenApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('tool-highlighter-a')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('width-selector')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('active-width-20')), findsOneWidget);

    await tester.timedDragFrom(
      const Offset(380, 260),
      const Offset(100, 35),
      const Duration(milliseconds: 150),
    );
    await tester.pumpAndSettle();

    final stroke =
        _annotationPainter(tester).drawables.single as StrokeDrawable;
    expect(stroke.width, 20);
    expect(stroke.color.a, closeTo(highlighterOpacity, .001));
  });

  testWidgets('toggling the active tool returns to idle without a ring', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const PenApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Pointer / desktop (Ctrl+Shift+P)'));
    await tester.pumpAndSettle();
    expect(_annotationPainter(tester).showPointer, isTrue);

    await tester.timedDragFrom(
      const Offset(360, 200),
      const Offset(40, 20),
      const Duration(milliseconds: 100),
    );
    await tester.pumpAndSettle();
    expect(_annotationPainter(tester).drawables, isEmpty);

    await tester.tap(find.byKey(const ValueKey('tool-pen-a')));
    await tester.pumpAndSettle();
    await tester.timedDragFrom(
      const Offset(360, 210),
      const Offset(50, 20),
      const Duration(milliseconds: 100),
    );
    await tester.pumpAndSettle();
    expect(_annotationPainter(tester).drawables, hasLength(1));

    await tester.tap(find.byKey(const ValueKey('tool-pen-a')));
    await tester.pumpAndSettle();
    await tester.timedDragFrom(
      const Offset(400, 250),
      const Offset(40, 20),
      const Duration(milliseconds: 100),
    );
    await tester.pumpAndSettle();
    expect(_annotationPainter(tester).drawables, hasLength(1));
    expect(_annotationPainter(tester).showPointer, isFalse);
  });

  testWidgets('right-click on canvas returns to idle without a ring', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const PenApp());
    await tester.pumpAndSettle();

    expect(_annotationPainter(tester).showPointer, isFalse);

    final gesture = await tester.startGesture(
      const Offset(420, 240),
      buttons: kSecondaryMouseButton,
    );
    await gesture.up();
    await tester.pumpAndSettle();

    expect(_annotationPainter(tester).showPointer, isFalse);
  });

  testWidgets('quick color palette uses a compact square grid', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    SharedPreferences.setMockInitialValues({'expanded_colors': true});
    await tester.pumpWidget(const PenApp());
    await tester.pumpAndSettle();

    final palette = find.byKey(const ValueKey('quick-color-palette'));
    expect(palette, findsOneWidget);
    final box = tester.renderObject<RenderBox>(palette);
    // 2×N grid: width is two swatches, height taller than a single row.
    expect(box.size.width, lessThanOrEqualTo(56));
    expect(box.size.height, greaterThan(box.size.width));
  });

  testWidgets('mouse forward/back cycles rectangle slots only', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final outline = ToolSlot(
      id: 'rect-a',
      type: ToolType.rectangle,
      color: const Color(0xff56d364),
      thickness: 4,
    );
    final filled = ToolSlot(
      id: 'rect-b',
      type: ToolType.rectangle,
      color: const Color(0xffff5d73),
      thickness: 4,
      filled: true,
    );
    final pen = ToolSlot(
      id: 'pen-a',
      type: ToolType.pen,
      color: const Color(0xff35a7ff),
      thickness: 4,
    );
    SharedPreferences.setMockInitialValues({
      'tool_slots': [
        jsonEncode(pen.toJson()),
        jsonEncode(outline.toJson()),
        jsonEncode(filled.toJson()),
      ],
      'active_slot': 'rect-a',
      'slots_migrated_v2': true,
    });

    await tester.pumpWidget(const PenApp());
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('tool-rect-a')), findsOneWidget);
    expect(find.byKey(const ValueKey('tool-rect-b')), findsOneWidget);
    expect(_toolSelected(tester, 'rect-a'), isTrue);
    expect(_toolSelected(tester, 'rect-b'), isFalse);

    final forward = await tester.startGesture(
      const Offset(500, 300),
      buttons: kForwardMouseButton,
    );
    await forward.up();
    await tester.pumpAndSettle();

    expect(_toolSelected(tester, 'rect-b'), isTrue);
    expect(_toolSelected(tester, 'rect-a'), isFalse);

    final back = await tester.startGesture(
      const Offset(500, 300),
      buttons: kBackMouseButton,
    );
    await back.up();
    await tester.pumpAndSettle();
    expect(_toolSelected(tester, 'rect-a'), isTrue);
    expect(_toolSelected(tester, 'rect-b'), isFalse);
  });

  testWidgets('persists toolbar dock preference', (tester) async {
    SharedPreferences.setMockInitialValues({'toolbar_dock': 'right'});

    await tester.pumpWidget(const PenApp());
    await tester.pumpAndSettle();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('toolbar_dock'), 'right');
    expect(
      find.byTooltip('Dock toolbar • drag to move display'),
      findsOneWidget,
    );
  });

  testWidgets('persists screenshot folder preference', (tester) async {
    SharedPreferences.setMockInitialValues({
      'screenshot_folder': r'D:\Custom\Screen pen by Hamed MosaddeghianShots',
    });

    await tester.pumpWidget(const PenApp());
    await tester.pumpAndSettle();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('screenshot_folder'), r'D:\Custom\Screen pen by Hamed MosaddeghianShots');
  });

  testWidgets('minimize restores prior tool without drawing while collapsed', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const PenApp());
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byTooltip('Hide toolbar'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Hide toolbar'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Show toolbar (Ctrl+Shift+H)'), findsOneWidget);

    await tester.timedDragFrom(
      const Offset(400, 240),
      const Offset(80, 30),
      const Duration(milliseconds: 120),
    );
    await tester.pumpAndSettle();
    expect(_annotationPainter(tester).drawables, isEmpty);

    await tester.tap(find.byTooltip('Show toolbar (Ctrl+Shift+H)'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('tool-pen-a')), findsOneWidget);

    await tester.timedDragFrom(
      const Offset(400, 240),
      const Offset(80, 30),
      const Duration(milliseconds: 120),
    );
    await tester.pumpAndSettle();
    expect(_annotationPainter(tester).drawables, hasLength(1));
  });

  testWidgets('text tool places an inline caret without a dialog', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const PenApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('tool-text-a')));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(420, 240));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('inline-text-field')), findsOneWidget);
    expect(find.text('Add text'), findsNothing);
    expect(find.byType(AlertDialog), findsNothing);

    await tester.enterText(
      find.byKey(const ValueKey('inline-text-field')),
      'Hello board',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    final text = _annotationPainter(tester).drawables.single as TextDrawable;
    expect(text.text, 'Hello board');
  });

  test('pen icon stays on the classic edit glyph', () {
    expect(ToolType.pen.icon, Icons.edit_outlined);
    expect(ToolType.highlighter.icon, isNull);
    expect(ToolType.highlighter.toolbarIcon, isA<Widget>());
    expect(ToolType.text.icon, Icons.title);
  });
}

AnnotationPainter _annotationPainter(WidgetTester tester) {
  final paint = tester
      .widgetList<CustomPaint>(find.byType(CustomPaint))
      .firstWhere((widget) => widget.painter is AnnotationPainter);
  return paint.painter! as AnnotationPainter;
}

bool _toolSelected(WidgetTester tester, String slotId) {
  final material = tester.widget<Material>(
    find.descendant(
      of: find.byKey(ValueKey('tool-$slotId')),
      matching: find.byType(Material),
    ),
  );
  return material.color == const Color(0xff2d8ac7);
}
