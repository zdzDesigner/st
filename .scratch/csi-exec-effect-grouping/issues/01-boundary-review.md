Title: Candidate 27 CSI ExecPlan effect grouping
Status: completed

## Scope

- `st.c:csihandle()`
- `st.c:tsetmode()`
- `st_csi.zig`
- `st_mode.zig`

## Decision

- `csihandle()` already consumes the top-level `ZigCsiExecPlan`.
- Mode actions already return action fields from Zig.
- Unknown diagnostics and real side effects remain in C by design.

## Conclusion

Candidate 27 is closed. No new effect grouping is justified now.
