Title: Term main-state seam dirty range first slice
Status: completed

## Scope

- `st.c:tsetdirt()`
- `st.c:termapplydirtyrange()`
- `st_line.zig:st_tsetdirtrange()`

## Change

- Kept dirty range normalization in Zig through `st_tsetdirtrange()`.
- Moved C dirty array mutation into `termapplydirtyrange()` as the first small term state effect executor.
- Did not widen the ABI.

## Decision

This is a minimal term-state migration foothold: Zig decides the range, C applies the state effect. Future term candidates should expand this snapshot/update/effect style only where it reduces duplicated C decision logic.
