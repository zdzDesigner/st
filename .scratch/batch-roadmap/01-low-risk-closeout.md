Title: Batch 1 low-risk closeout
Status: completed

## Goal

Confirm the current shim-thinning candidates are closed before moving into larger state ownership work.

## Completed scope

- Search effect executor and scan transaction have been consolidated to the current useful boundary.
- Selection result executor has been consolidated to the current useful boundary.
- Draw, resize, CSI, input, mode, scroll/edit and external pipe are already plan-driven.
- ABI cleanup round 3 found no additional obsolete exports.
- Test layer rebalance round 2 found no new wide adapter surface.

## Decision

Batch 1 is complete. Do not continue mechanical helper merging or shallow export scans.

## Validation boundary

Use `git diff --check`, `zig build abi-check`, `zig build test`, `zig build`, and `timeout 5 ./zig-out/bin/st` after each later batch.
