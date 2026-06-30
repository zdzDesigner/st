Title: Candidate 18 Search scan transaction consolidation
Status: completed

## Scope

- `st.c:searchscan()`
- `st.c:searchresetscanmatches()`

## Change

- Added `searchresetscanmatches()` to centralize match count reset before a scan transaction.
- Kept line traversal, history access, realloc and match array writes in C.

## Decision

This is the current useful boundary. Further scan consolidation would require moving line/history ownership or match array ownership, which remains outside this slice.
