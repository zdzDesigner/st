Title: Candidate 26 Input mainline state ownership
Status: completed

## Scope

- `st.c:tputc()`
- `st.c:tcontrolcode()`
- `st.c:eschandle()`
- `st_setchar.zig`
- `st_control_esc.zig`

## Decision

- Input already consumes `InputControlPlan`, `InputEscPlan`, `InputEscFlowPlan`, `PutcPrepare` and write plans.
- C's remaining work is updating terminal globals, collecting string bytes and executing platform effects.
- Moving further requires ownership migration for `term.esc`, string sequence buffers or glyph writes.

## Conclusion

Candidate 26 is closed as a small-slice candidate. It should be reopened only as a deliberate input state ownership project.
