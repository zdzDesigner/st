Title: 新一轮 architecture friction 排名
Status: completed

## Ranking

1. **Attr scan consolidation**
   - 关注：`st_tattrset` / `st_tlineattrset`
   - 原因：同一领域有两条 interface，未来若 caller 增多，值得评估是否需要更深的统一 scan module。

2. **Cursor/Edit action seam（仅在新需求触发时）**
   - 关注：`tdeletechar` / `tinsertblank` / `tnewline` / `treverseindex`
   - 原因：当前仍有副作用顺序在 C，但尚不足以支撑新 seam；若后续新增类似 action，再重新评估。

3. **Draw pipeline refresh**
   - 关注：`st_drawframeplan` / `st_drawregionplan`
   - 原因：当前已较深，但 draw 仍是高复杂区域，未来值得单独复查。

4. **Line attr/output surface**
   - 关注：`st_tattrset` / `st_tlineattrset` / `st_tdumplineplan` / `st_externalpipeplan`
   - 原因：当前通过 deletion test，短期内不建议再拆。

## Closed candidates

- Candidate 5：Mode actions，已到当前收益边界
- Candidate 6：adapter tests 收窄，已到当前收益边界
- Candidate 7：浅 export deletion test，已删到当前收益边界
- Candidate 8：Cursor/Edit boundary review，当前关闭
- Candidate 9：CSI/State/Misc boundary review，当前关闭

## Next recommendation

如果继续做代码而不是只做规划，下一候选优先看 **Attr scan consolidation**。
