Title: Candidate 28 Resize/Draw dirty contract review
Status: completed

## Scope

- `st.c:tresize()`
- `st.c:tsetdirt()`
- `st.c:draw()`
- `st_state.zig`
- `st_cursor.zig`

## Decision

- Resize is already `ZigResizeExecPlan` driven.
- Draw is already `ZigDrawExecPlan` driven.
- Dirty range updates are already normalized by Zig and applied through a C effect helper.
- There is still no shared repeated contract that warrants a wider frame/viewport module.

## Conclusion

Candidate 28 remains closed. Avoid a broad frame/viewport abstraction until repeated state fields appear.
