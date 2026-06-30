Title: Candidate 21 Selection snap flow review
Status: completed

## Scope

- `st.c:selsnap()`
- `st_selection.zig:SnapWordIterator`
- `st_selection.zig` snap line helpers

## Decision

- `SNAP_WORD` already uses a two-phase iterator: Zig requests facts, C reads `TLINE(...)` / delimiter / line length / wrap facts, Zig resolves the next step.
- `SNAP_LINE` already delegates loop step decisions to Zig.
- C's remaining work is fact reading, not selection rule ownership.

## Conclusion

Candidate 21 is closed at the current boundary. Moving `TLINE(...)` access or delimiter reads would be state ownership migration, not a small shim-thinning slice.
