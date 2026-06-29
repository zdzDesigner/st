Title: 复查 Attr scan consolidation
Status: completed

## Scope

- `st_line.zig`
- `st_line_core.zig`
- `st.c:tattrset()`
- `st.c:tsetdirtattr()`

## Findings

- 当前有两条 interface：
  - `st_tattrset(lines, row, col, attr)`：跨多行 scan
  - `st_tlineattrset(line, col, attr)`：单行 scan
- 它们共享同一个 domain implementation：`line_core.Lines.hasAttr()` / `line_core.Line.hasAttr()`。
- C caller 只有两个：
  - `tattrset(int attr)`
  - `tsetdirtattr(int attr)`
- 如果现在强行把两条 interface 合并成新 seam，C 仍然必须知道“全屏 scan”和“逐行 scan”是两个不同 use case，复杂性不会消失，只会移动到更宽的 interface。

## Decision

- 当前不创建新的 attr scan module seam。
- 保持 `st_tattrset` / `st_tlineattrset` 两条 interface。
- 若未来出现第三个 caller，或者 attr scan 需要统一返回 richer result（例如 dirty range / first hit / all hit），再重开本候选。

## Conclusion

Attr scan consolidation 在当前阶段不是高价值 refactor。它通过 deletion test，但不通过 deepening test：新 seam 的 leverage 不足，locality 收益也不明显。
