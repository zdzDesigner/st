Title: Manual search delete boundary
Status: completed

## Decision

Keep `searchapplyinputdelete(start, end)` as the manual/public delete shim for now.

## Reason

`searchapplycursor()` no longer calls this path. The remaining caller is `searchdelete(start, end)`, which provides an explicit external range and still needs C to perform `memmove()` on `search.input`.

## Reopen Trigger

Reopen if manual delete gains state/effect semantics beyond a raw range deletion.
