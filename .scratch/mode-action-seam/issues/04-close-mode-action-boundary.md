Title: 收束 Mode action boundary
Status: completed

## Decision

Candidate 5 到达当前收益边界。

## Zig owns

- alternate screen / cursor save-load action order
- mouse mode pointer/clear/set action order
- origin action order
- visibility / simple bit / xsetmode 最终写入值

## C keeps

- `allowaltscreen` gate
- `tcursor`
- `tclearregion`
- `tswapscreen`
- `xsetpointermotion`
- `xsetmode`
- `tmoveato`
- `MODBIT(...)` 最终副作用执行
- unknown diagnostics stderr 输出

## Conclusion

不再继续扩大 `ZigModePlan`。继续加字段只会让 interface 变宽，边际收益下降。下一候选转向 adapter tests 收窄。
