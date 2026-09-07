# Dependency Graph

## Hard dependencies

- T03 -> T04 (tests and release notes depend on the final candle API and
  toolbar keys)

## Soft dependencies

- None

## Shared-write conflicts

- T03 writes `lib/main.dart`; T04 writes tests and release metadata.
- T03 and T04 must remain sequential because the removed pattern API changes
  test contracts.

## Read-only overlaps

- T04 reads candle helpers, `ToolType`, saved-slot migration behavior, and
  toolbar keys from `lib/main.dart`.

## Waves

```text
Wave 1: T03
Wave 2: T04
```

## Parallelism notes

- T03 is the only task in Wave 1.
- T04 unlocks only after T03 verification and handoff.

## Validation

- Hard-dependency cycles: none
- Unsafe parallel groups: none
- Integration dependencies accounted for: yes
