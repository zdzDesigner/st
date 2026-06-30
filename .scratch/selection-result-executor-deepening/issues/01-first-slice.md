Title: Candidate 20 Selection result executor deepening
Status: completed

## Scope

- `st.c:selscroll()`
- `st.c:selectionapplyscrollresult()`

## Change

- Added `selectionapplyscrollresult()` so `selscroll()` no longer expands clear/update effect handling inline.

## Decision

Selection result consumption remains a C executor because `selclear()` and dirty effects mutate C global state.
