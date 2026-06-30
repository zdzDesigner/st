Title: Batch 6 ABI/test final sweep
Status: completed

## Goal

Delete obsolete ABI and rebalance tests after the previous batches.

## Findings

- No additional obsolete export was found after the latest helper consolidation.
- No new wide adapter surface was introduced.
- No test rebalance is required in this batch.

## Decision

Batch 6 is complete. Continue using `zig build abi-check` for any future ABI-changing slice.
