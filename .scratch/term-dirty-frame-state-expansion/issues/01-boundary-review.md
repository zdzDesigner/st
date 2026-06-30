Title: Candidate 23 Term dirty/frame state expansion
Status: completed

## Scope

- `st.c:tsetdirt()`
- `st.c:termapplydirtyrange()`
- `st.c:draw()` / `drawregion()`

## Decision

- Dirty range normalization is already in Zig through `st_tsetdirtrange()`.
- Dirty mutation is centralized in `termapplydirtyrange()`.
- Draw is already driven by `ZigDrawExecPlan` and `st_drawregionplan()`.

## Conclusion

Candidate 23 is closed until a broader `term` state ownership slice exists. Remaining dirty writes are C state effects.
