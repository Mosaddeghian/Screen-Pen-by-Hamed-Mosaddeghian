# Execution Metadata

## Readiness

```text
PLAN READY

Tasks: 2
Parallel: 0
Sequential: 2
Waves: 2

GPT-5.6 Luna — High effort: 1
Grok 4.6 — Medium effort: 1
Grok 4.6 — High effort: 0
Variant: STANDARD / NON-FAST
Fast: FORBIDDEN

Unresolved dependencies: 0
Conflicts: 0
Routing mismatches: 0
Unassigned tasks: 0
```

## Task schema

### T03 — Remove patterns and make candle colors functional

- Goal: Keep only drawable candlestick slots, provide green and red defaults,
  make each slot color the actual candle color, and migrate saved pattern slots.
- Type: implementation
- Depends on: none
- Parallel group/wave: Wave 1
- Files/symbols in scope: `lib/main.dart` only (`CandlePattern`,
  `ToolType`, `ToolSlot`, candle helpers and drawable, default slots, saved-slot
  migration, drawing gestures, painter switches, `_AddSlotDialog`, `kAppVersion`)
- Conflict scope: `lib/main.dart`
- Risk: high
- Executor class: HIGH
- Model: Grok 4.6
- Effort: Medium
- Variant: STANDARD / NON-FAST
- Fast: FORBIDDEN
- Model ID: cursor-grok-4.6[effort=medium]
- Custom Agent: po-high-grok46
- Context budget: this task section, `.cursor/memory/overview.md`,
  `.cursor/memory/decisions.md`, and the listed symbols; do not edit tests or
  release docs
- Inputs: existing 1.4.0 candlestick implementation in `lib/main.dart`
- Outputs: updated `lib/main.dart`; handoff `.agent/handoffs/T03.md`
- Acceptance criteria:
  - `ToolType` and the add-tool dialog expose no candlestick pattern option.
  - Fresh and migrated tool lists contain two regular candle slots, one green
    and one red.
  - Selecting a candle slot and changing its color changes newly drawn candle
    bodies and wicks.
  - Old saved pattern slots are removed during migration, old saved candle
    drawings remain readable, and migration does not duplicate candle defaults.
  - `kAppVersion` is `1.5.0`.
- Verification: `flutter analyze lib/main.dart`
- Handoff required: yes

### T04 — Update tests and release notes

- Goal: Replace pattern tests with coverage for the two defaults, color-aware
  candle drawing, migration cleanup, and the 1.5.0 release metadata.
- Type: test and documentation
- Depends on: T03
- Parallel group/wave: Wave 2
- Files/symbols in scope: `test/widget_test.dart`, `CHANGELOG.md`, `README.md`,
  `pubspec.yaml`, and `.agent/execution-state.md`
- Conflict scope: those files only
- Risk: low
- Executor class: LOW
- Model: GPT-5.6 Luna
- Effort: High
- Variant: STANDARD / NON-FAST
- Fast: FORBIDDEN
- Model ID: gpt-5.6-luna[effort=high]
- Custom Agent: po-low-luna
- Context budget: T03 handoff plus current candle helpers, toolbar keys, and
  existing test structure; do not edit `lib/main.dart`
- Inputs: verified T03 implementation
- Outputs: tests and release notes; handoff `.agent/handoffs/T04.md`
- Acceptance criteria:
  - Tests contain no references to removed pattern types or keys.
  - Tests verify green/red defaults and that changing a candle slot color is
    reflected in a new `CandleGroupDrawable`.
  - `CHANGELOG.md`, `README.md`, and `pubspec.yaml` describe version 1.5.0.
- Verification: `flutter test`, `flutter analyze`, and `git diff --check`
- Handoff required: yes
