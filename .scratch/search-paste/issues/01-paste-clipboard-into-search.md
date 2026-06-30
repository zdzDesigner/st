Title: Fix clipboard paste into search input
Status: completed

## Bug

When search input was active, clipboard paste still went through `ttywrite()`, so pasted text was sent to the child PTY instead of being inserted into the search query.

Keyboard paste shortcuts were also swallowed by the search-input key handling branch before normal shortcut dispatch could call `clippaste()` or `selpaste()`.

## Fix

`x.c:selnotify()` now routes selection data to `searchinput()` while `searchinputactive()` is true. Normal terminal paste still uses bracketed paste and `ttywrite()`.

`x.c:kpress()` now lets `clippaste()` and `selpaste()` shortcuts run while search input is active, so both clipboard paste and primary selection paste can reach `selnotify()`.

## Validation

- `git diff --check`
- `zig build abi-check`
- `zig build test`
- `zig build`
- `timeout 5 ./zig-out/bin/st`
