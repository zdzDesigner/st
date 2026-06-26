Title: 删除旧 word snap shim 并收窄 adapter surface
Status: ready-for-agent

## What to build

在新的 iterator 路径稳定后，删除 selection word snap 的过渡 ABI 和不再需要的 adapter smoke surface，让 `st_line.zig` 与 `st_zig.h` 只保留仍被 C shim 实际消费的最小接口。

## Acceptance criteria

- [ ] 失效的 `st_selsnapwordplan()` 和 `st_selsnapwordloopstep()` 路径被删除，或被收缩到不再对 C 暴露
- [ ] `st_line.zig` 与 `st_zig.h` 的 selection snap 导出面缩小，且 `abi-check` 保持通过
- [ ] 仅验证旧 ABI 转发的 smoke tests 被删除或降级为新接口对应测试

## Blocked by

- `.scratch/selection-snap-word-iterator/issues/02-wire-selsnap-word-loop-to-iterator.md`
