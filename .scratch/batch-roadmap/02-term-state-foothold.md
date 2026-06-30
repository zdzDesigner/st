Title: Batch 2 term state foothold
Status: completed

## Goal

Find a safe foothold for moving `term` main state toward snapshot/update/effect ownership.

## Findings

- Dirty range normalization is already in Zig through `st_tsetdirtrange()`.
- Dirty mutation is already centralized in `termapplydirtyrange()`.
- Cursor clamp, newline, draw cursor adjustment and save/load action planning are already in Zig.
- Draw frame/region orchestration is already driven by `ZigDrawExecPlan` and `ZigDrawRegionPlan`.

## Decision

Batch 2 is closed at the current boundary. A wider `TermSnapshot`/`TermStateUpdate` now requires deliberate state ownership migration, not another low-risk shim-thinning slice.

## Reopen trigger

Reopen only when choosing a concrete `term` state ownership project, such as dirty ownership, cursor ownership, or viewport ownership.
