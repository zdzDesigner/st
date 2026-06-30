Title: Candidate 25 Term scroll/edit state boundary
Status: completed

## Scope

- `st.c:tscrollup()` / `tscrolldown()`
- `st.c:tdeletechar()` / `tinsertblank()`
- `st.c:tclearregion()`
- `st_edit.zig`
- `st_state.zig`

## Decision

- Scroll/edit paths already consume Zig plans.
- C's remaining work is line pointer swap, history pointer swap, `memmove`, clear-region mutation and selection scroll effect.
- No repeated decision ordering was found that justifies a wider seam.

## Conclusion

Candidate 25 is closed. Reopen only if new scroll/edit actions create duplicated C ordering.
