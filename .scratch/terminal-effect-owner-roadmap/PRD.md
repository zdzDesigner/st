# Terminal Effect Owner Roadmap

## Goal

以 `docs/terminal-effect-ordering.md` 为直接基准，把 terminal effect ordering 护栏落到可持续执行的 owner roadmap：每次只选择一个 owner seam，先做边界复查，再决定是否进入实现切片，避免把原子提交、顺序事务或 C 资源 ownership 误拆进 Zig。

## Evidence

- `docs/terminal-effect-ordering.md:5` 定义该文档是后续拆分 `st.c` / `x.c` 的迁移护栏。
- `docs/terminal-effect-ordering.md:11` 至 `docs/terminal-effect-ordering.md:74` 定义必须原子提交、必须先后执行、纯决策、只能留在 C executor 四类边界。
- `docs/zig-architecture.md:77` 要求后续拆分 `st.c` / `x.c` 前必须先查 `docs/terminal-effect-ordering.md`。
- `docs/c-responsibility-map.md:264` 至 `docs/c-responsibility-map.md:275` 给出 owner 优先级与风险排序。
- `.scratch/term-frame-owner/PRD.md:28` 至 `.scratch/term-frame-owner/PRD.md:43` 记录 Dirty + Cursor + Draw 首批切片已完成并通过验证。

## Non-goals

- 不把所有 owner 一次性迁到 Zig。
- 不迁移 X11、PTY、clipboard、fd、font、line buffer、history buffer 等 C 持有资源 ownership。
- 不继续机械删除 ABI helper；只有明确 owner seam 和验证信号时才进入实现。
- 不重排 `tputc()` graphic commit、scroll、resize、draw、reset、focus/color 等已标记为顺序敏感的路径。

## Owner Slice Queue

顺序按依赖链和风险梯度排列，不等同于实施优先级；实施优先级仍以 `docs/c-responsibility-map.md` 的迁移优先级表为准。

1. `01-owner-roadmap-freeze`: completed
2. `02-escape-machine-boundary-review`: completed
3. `03-line-history-transaction-boundary-review`: completed
4. `04-selection-ownership-reopen-check`: completed
5. `05-search-buffer-ownership-reopen-check`: todo
6. `06-platform-effect-ordering-plan`: todo

## Validation

- `zig build abi-check`
- `zig build test`
- `zig build`
