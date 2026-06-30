Title: Candidate 29 ABI surface cleanup round 3
Status: completed

## Scope

- `st_zig.h`
- `export fn st_*`

## Decision

- No additional obsolete export was found in this round.
- Existing remaining exports are still C shim entry points for domain plans or state transitions.

## Conclusion

Candidate 29 is closed. Run `zig build abi-check` after any future ABI-changing slice.
