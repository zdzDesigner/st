Title: 复查 Draw pipeline refresh
Status: completed

## Scope

- `st.c:draw()` / `drawregion()`
- `st_cursor.zig:st_drawframeplan()`
- `st_cursor.zig:st_drawregionplan()`

## Findings

- `draw()` 当前仍在 C 持有一段清晰但较厚的控制流：
  - `xstartdraw()` gate
  - `searchscan()` 条件刷新
  - `drawregion()` loop
  - `xdrawcursor()`
  - `xfinishdraw()`
  - `xximspot()`
- `st_drawframeplan()` 和 `st_drawregionplan()` 已经把部分决定迁到了 Zig，但 C 仍然持有完整 frame orchestration。
- 这是真 friction：C 不只是在执行副作用，还在决定这些副作用的编排顺序。

## Decision

- Draw pipeline refresh 是当前最值得继续做代码的下一候选。
- 下一条切片不应直接搬完整 draw loop，而应先设计更 coarse-grained 的 `DrawExecPlan`：
  - 是否 search scan
  - dirty region iteration strategy
  - cursor draw gate
  - imspot gate

## Conclusion

相较于 Attr scan consolidation，Draw pipeline refresh 有更高的 leverage 和 locality 收益。后续如果继续做代码，优先进入这个候选。
