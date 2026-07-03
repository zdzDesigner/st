Title: drawregion transaction executor
Status: ready-for-agent
Progress: completed

## Goal

把 `drawregion()` 从 C 手写 dirty scan loop 切到 Zig draw region transaction + C effect executor。

## Scope

- `st.c:drawregion()`
- `st_cursor.zig:st_drawregiontransaction(...)`
- `st_zig.h` draw region transaction declaration
- `st_cursor.zig` draw region tests

## Boundary

- 保持 `draw()` 顶层顺序不变：`searchscan -> drawregion -> xdrawcursor -> xfinishdraw`。
- 只替换 dirty region 的“逐行查找 + 清 dirty + xdrawline”执行方式。
- 不迁移 `xdrawline()` ownership，不新增 platform resource ownership。

## Dependencies

- `docs/zig-architecture.md`
- `docs/architecture-flow.md`
- 现有 `ZigDrawRegionTransaction` 类型和 `platform_effect_region_*` kind

## Blocked by

- 无

## Acceptance criteria

- `drawregion()` 不再自己循环调用 `st_drawregionplan()` 和手写 `term.dirty[y] = 0`。
- `st_drawregiontransaction(...)` 通过头文件导出，C 侧只解释 transaction steps。
- Zig 单测覆盖 draw line / clear dirty / advance 顺序。
- `zig build abi-check`、`zig build test`、`zig build` 通过。

## Validation

- `zig build abi-check`
- `zig build test`
- `zig build`

## Comments

- 2026-07-02 Observe: 依据 `st.c:2891-2931`、`st_cursor.zig:334-364`、`docs/architecture-flow.md:237` 选择本切片。该切片复用既有 transaction seam，不碰 frame 顶层顺序，属于 `Dirty + Cursor + Draw` owner 的最小可执行第一刀。
- 2026-07-02 Draft/Review round 1: `coder` 先完成 transaction executor 落地；`code-reviewer` 指出需要补 export 可见性核实、overflow fail-fast、C 侧边界检查和等价性测试。主代理复核后确认 export 已在实际改动中解决，剩余项进入下一轮修复。
- 2026-07-02 Draft/Review round 2: `coder` 补 `addDrawRegionStep()` overflow panic、`drawregion()` step 边界检查和 default fail-fast，并新增 empty / non-contiguous / y1>0 三组 Zig tests。`code-reviewer` 复审结果：无 critical/high，允许进入验证；仅建议删除 ADVANCE 分支 dead write，已由主代理顺手清理。
