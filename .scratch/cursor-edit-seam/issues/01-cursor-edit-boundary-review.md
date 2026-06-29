Title: 复查 Cursor/Edit seam 边界
Status: completed

## Scope

- `st_cursor.zig`
- `st_edit.zig`
- `st.c` 中对应 caller

## Findings

- `st_tdeletechar` / `st_tinsertblank` 虽然 caller 各只有一个，但它们隐藏了 count clamp、memmove source/destination 计算和 clear range 计算。
- `st_tnewline` / `st_treverseindex` 隐藏了 scroll vs move 的分支，不属于“删除后复杂度直接消失”的浅 export。
- `st_tmoveto`、`st_drawframeplan`、`st_drawregionplan`、`st_tcursorplan` 都仍承载 cursor/draw 领域规则。

## Decision

- Candidate 8 在当前边界不继续做机械 deletion。
- 只有当未来要把 memmove/clear 的执行顺序整体收口到更深的 action seam 时，才值得重新打开。

## Conclusion

Cursor/Edit 当前没有像 `st_tmoveato_y`、`st_tlineinregion` 这种明显继续可删的浅 export。停止本候选，避免为了“继续删”而把领域计算推回 C。
