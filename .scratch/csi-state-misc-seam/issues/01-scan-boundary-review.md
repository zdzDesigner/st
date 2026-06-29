Title: 复查 CSI/State/Misc seam 边界
Status: completed

## Scope

- `st_csi.zig`
- `st_state.zig`
- `st_misc.zig`

## Findings

- `st_csiexecplan` 已经是顶层聚合 plan，不适合再做细碎 deletion。
- `st_tsetscroll`、`st_tresizeexecplan`、`st_tresetplan`、`st_tresettabs` 仍承载 state/resize/reset 领域规则。
- `st_misc.zig` 目前已只剩真正有价值的杂项逻辑；`st_ttywritechunk` 已删除后，未发现新的明显 shallow export。

## Decision

- Candidate 9 当前不继续改代码。
- 该区域后续只有在出现新的重复副作用顺序或宽 interface 时才重新打开。

## Conclusion

CSI/State/Misc 当前到收益边界，继续机械扫描不会产生高价值 refactor。
