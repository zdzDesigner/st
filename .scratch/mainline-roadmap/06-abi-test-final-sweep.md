Title: Mainline 6 ABI/Test Final Sweep
Status: completed

## Goal

Check whether this mainline pass introduced obsolete ABI or a new adapter test imbalance.

## Findings

- No code seam was widened in this pass.
- No new Zig ABI was added.
- No additional obsolete export or test layer imbalance was found.

## Decision

No cleanup required. Continue using `zig build abi-check` for future ABI-changing slices.
