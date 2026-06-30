Title: Candidate 24 Term cursor state snapshot/update
Status: completed

## Scope

- `st.c:tmoveto()`
- `st.c:tmoveato()`
- `st.c:tnewline()`
- `st.c:tcursor()`
- `st_cursor.zig`

## Decision

- Cursor clamp, newline, draw cursor adjustment and cursor save/load action planning are already in Zig.
- C writes `term.c`, `term.ocx` and `term.ocy` as state effects.
- A larger cursor snapshot/update seam would mainly wrap existing C field assignments without moving new decision logic.

## Conclusion

Candidate 24 is closed at the current boundary. Reopen only when a larger `term` ownership slice exists.
