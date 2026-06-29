Title: 复查 line adapter surface 与 shallow exports
Status: completed

## What to evaluate

复查 `st_line.zig` 剩余 exports，并对当前 repo 的浅层 `export fn st_*` 做 deletion test。目标是只删除“删除后复杂度消失”的 pass-through，不把领域规则推回 C shim。

## Line adapter classification

- `st_tlinelen`：保留。隐藏 trailing space、wrap、wide dummy 等 line length 规则。
- `st_tputtab`：保留。隐藏 tab stop 搜索和边界 clamp。
- `st_tattrset`：保留。跨多行 attr scan，删除后会把扫描规则推回 C。
- `st_tlineattrset`：保留。单行 attr scan，与跨多行 scan 共享 line 语义；当前两个 call sites 不足以证明需要合并成更大 interface。
- `st_tdumplineplan`：保留。隐藏 dump 输出范围规则。
- `st_tsetdirtrange`：保留。虽然 interface 小，但它把 dirty range clamp 集中在 `Viewport`，符合 C 只执行 dirty write effect 的原则。
- `st_externalpipeplan`：保留。直接复用 `VisualLine`、line length 和 wrap newline 语义；暂不抽 `st_output.zig`。

## History decision

- `st_tlinehistplan` 已下沉到 `st_search.zig`。
- 原因：history ring 映射与 search/history locality 更一致，继续留在 `st_line.zig` 会让 line adapter 保留非 line 职责。

## Output module decision

- 暂不创建 `st_output.zig`。
- `st_tdumplineplan` 与 `st_externalpipeplan` 都与 line output 相关，但当前没有第三个复用方能证明新 seam 是 real seam。
- 当前保持 `st_line.zig` 作为 line/external pipe adapter，比新增 shallow output module 更深。

## Repo shallow export scan

本轮扫描的可疑项：

- `st_tlineinregion`：保留。两个 C call sites 共享 scroll region rule；删除会复制 range check。
- `st_tmoveato_y`：保留。属于 cursor origin rule；删除会把 cursor origin 语义推回 C。
- `st_tdefutf8` / `st_tdeftran`：保留。属于 mode/charset selector；删除会把 switch 规则推回 C。
- `st_ttywritechunk`：保留。虽然 interface 小，但隐藏扫描 CR chunk 的 loop。
- Search/Selection adapter forwarding exports：保留。它们是 C ABI adapter，interface 后面是 `SearchModel` / `SelectionModel` 的 domain behaviour。

## Conclusion

本轮对 `st_line.zig` 保持不删，但对跨模块 deletion test 额外删除了两条真正通过测试的浅 export：`st_tmoveato_y`、`st_tlineinregion`。`st_line.zig` 已足够收窄；下一步不应继续机械拆分 line adapter，而应转向新的 high-friction module。
