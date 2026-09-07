# Project overview

Screen pen by Hamed Mosaddeghian is a Flutter Windows annotation overlay and
whiteboard app. The main application code is in `lib/main.dart`.

- `AnnotationWorkspace` owns canvas state, tool slots, preferences, and input.
- `ToolSlot` describes toolbar tools and is saved with `SharedPreferences`.
- `Drawable` objects are painted by `AnnotationPainter` and saved as JSON.
- Run with `flutter run -d windows`; verify with `flutter analyze` and
  `flutter test`.
- Release metadata is kept in `pubspec.yaml`, `lib/main.dart`, and
  `CHANGELOG.md`.
