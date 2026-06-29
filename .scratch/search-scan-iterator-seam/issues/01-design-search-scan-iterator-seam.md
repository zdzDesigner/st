Title: 设计 Search scan iterator seam
Status: completed

## What to build

把 `searchscanline()` 与 Zig 的交互从散参数 `st_searchlineplan()` 收口为 iterator seam。这个 slice 只迁 scan line 的 loop state 与决策，不迁 `search.matches` 指针 ownership。

## Proposed seam

- Zig 负责：
  - `x` 扫描进度
  - `nmatches/cap` 的下一状态
  - 当前 line 是否命中
  - append / grow_append / stop 决策
  - `SearchMatch` 值对象内容
- C 负责：
  - `TLINE(...)` / history line 获取
  - `xrealloc(search.matches, ...)`
  - `SearchMatch` 数组写入
  - `SearchMatchesState` 最终落回

## Interface

- `ZigSearchScanLineState`
  - `x`
  - `nmatches`
  - `cap`
  - `y`
  - `scr`
- `st_searchscanlineiter(line, col, query, qlen, state)`
  - 返回 `ZigSearchScanLineStep`
  - `kind` 表达 stop / append / grow_append
  - `state` 表达下一轮 scan state
  - `match` 表达 C 要写入数组的值对象

## Ownership decision

暂不迁 `matches` ownership。原因是 C 仍自然持有 `SearchMatch *matches`、`xrealloc/free` 和数组写入；iterator seam 已经把 loop state 与决策集中到 Zig，继续迁 pointer ownership 会增加生命周期协议但不会删除主要 C effect。

## Acceptance criteria

- [x] 删除旧 `st_searchlineplan` ABI
- [x] C scan loop 消费 iterator state
- [x] 测试覆盖 append / grow_append / stop / scan current 归一化
- [x] 文档记录不迁 `matches` ownership 的结论
