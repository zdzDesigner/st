Title: Candidate 19 Search buffer ownership re-evaluation
Status: completed

## Scope

- `search.query`
- `search.input`
- `search.matches`

## Decision

- `query` still depends on C-side UTF-8 decode and pointer replacement.
- `input` still depends on C-side `xrealloc`, `memmove`, `memcpy` and nul termination.
- `matches` still depends on C-side `xrealloc` and array writes while scanning terminal/history lines.

## Conclusion

Candidate 19 is closed. Do not migrate buffer ownership yet; protocol cost is still higher than shim-thinning benefit.
