Title: freeze terminal effect owner roadmap
Status: ready-for-agent
Progress: completed

## Goal

把 `docs/terminal-effect-ordering.md` 的迁移护栏和 `docs/c-responsibility-map.md` 的 owner 分类收敛成可执行 owner roadmap，明确后续切片顺序与阻塞边界。

## Scope

- 只创建 roadmap PRD 和 issue 队列。
- 复用已完成的 `term-frame-owner` 状态，不重复规划 Dirty + Cursor + Draw。
- 后续 owner 只进入 boundary review，不直接承诺实现迁移。

## Boundary

- 不修改行为代码。
- 不修改已有 completed issue。
- 不把 roadmap issue 当作实际 ownership 已迁移的证据。

## Dependencies

- `docs/terminal-effect-ordering.md`
- `docs/c-responsibility-map.md`
- `docs/zig-architecture.md`
- `docs/architecture-flow.md`
- `.scratch/term-frame-owner/PRD.md`

## Blocked by

- None - can start immediately

## Acceptance criteria

- [x] 新增 `.scratch/terminal-effect-owner-roadmap/PRD.md`。
- [x] 新增后续 owner boundary review issues。
- [x] Roadmap 明确 `docs/terminal-effect-ordering.md` 是直接基准。
- [x] Roadmap 明确不迁移 C 资源 ownership。

## Validation

- `zig build abi-check`
- `zig build test`
- `zig build`

## Comments

- 2026-07-03 Frame: 当前大模块目标继承为基于 `docs/terminal-effect-ordering.md` 继续推进 owner 拆分。已读证据：`docs/terminal-effect-ordering.md`、`docs/c-responsibility-map.md`、`docs/zig-architecture.md`、`docs/architecture-flow.md`、`.scratch/term-frame-owner/*`。
- 2026-07-03 Slice: Dirty + Cursor + Draw 已在 `.scratch/term-frame-owner` 完成。新的 roadmap 从剩余 seam 中选择低风险、可验证的 boundary review 切片开始，避免直接进入高风险 code migration。
- 2026-07-03 Act: 已创建 `.scratch/terminal-effect-owner-roadmap/PRD.md` 和 6 个 issue；本 issue 表示 roadmap 冻结完成。
- 2026-07-03 Review: `code-reviewer` 未发现 critical/high；补充说明 Owner Slice Queue 的顺序按依赖链和风险梯度排列，不等同于 `docs/c-responsibility-map.md` 的实施优先级。
