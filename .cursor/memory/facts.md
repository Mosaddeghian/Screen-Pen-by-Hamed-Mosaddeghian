# Facts

- The app stores tool slots under the `tool_slots` preference and canvas
  drawables under `canvas_data`.
- Candlestick defaults use `candle-green` and `candle-red`; saved pattern slots
  are cleaned by the `slots_migrated_v5` migration.
- The delivered app version is `1.5.1` with Windows build number `7`.
- The Windows release workflow builds with `flutter build windows --release`.
- After every app change, rebuild the portable version too: run
  `flutter build windows --release`, then zip the contents of
  `build\windows\x64\runner\Release` into
  `dist/ScreenPen-v<version>-portable-win64.zip` (same steps as
  `.github/workflows/release.yml`). Replace the outdated zip in `dist/`.
- Hamed wants the portable zip rebuilt right away with every change. If
  `pen.exe` is locked because the app is still open, ask once with clickable
  options; on approval close it and rebuild.
- Current work should keep the project version and changelog synchronized.
