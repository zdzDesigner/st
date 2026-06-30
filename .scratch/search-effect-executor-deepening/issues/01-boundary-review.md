Title: Candidate 17 Search effect executor deepening
Status: completed

## Scope

- `st.c:searchapplyresourceeffect()`
- `st.c:searchapplyvieweffect()`
- `st.c:searchapplyfloweffect()`
- `st.c:searchapplyqueryreplace()`

## Decision

- 当前不新增 Zig ABI。
- Search effect executor 已经按 resource/view/flow/query replace 分层。
- 剩余代码主要是 `free`、`xrealloc`、`memmove`、`memcpy`、`redraw`、`searchjump` 这类 C 自然 effect。

## Conclusion

Candidate 17 当前关闭。继续合并 helper 不会让 C 更薄，只会隐藏必要 effect 顺序。
