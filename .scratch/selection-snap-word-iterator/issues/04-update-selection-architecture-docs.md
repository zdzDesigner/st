Title: 同步 Selection 架构文档
Status: ready-for-agent

## What to build

更新 Selection 相关架构文档，使其准确反映 `selsnap()` word loop 的新 C/Zig seam、Zig 持有的迭代逻辑，以及保留在 C 的 reader/effect 职责和验证基线。

## Acceptance criteria

- [ ] `docs/zig-architecture.md` 更新 Selection snap 当前状态与迁移进度
- [ ] `docs/architecture-flow.md` 更新 Selection flow，明确 word loop 已由 Zig 主导、C 只保留事实读取与副作用
- [ ] 文档中的描述与实际代码路径一致，不再引用已删除的旧 selection snap seam

## Blocked by

- `.scratch/selection-snap-word-iterator/issues/02-wire-selsnap-word-loop-to-iterator.md`
