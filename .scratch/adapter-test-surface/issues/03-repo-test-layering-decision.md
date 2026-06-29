Title: Repo 级测试分层 decision
Status: completed

## Decision

- adapter smoke tests：只验证 extern/domain/extern 转换和关键字段不丢失
- domain tests：验证行为、顺序、edge cases 和 deletion-sensitive logic

## Module status

- `st_search.zig`：第一轮 smoke 收窄完成，当前到边界
- `st_selection.zig`：第一轮 smoke 收窄完成，当前到边界
- `st_line.zig`：当前测试本身就是 line domain 行为，不继续机械收窄
- `st_mode.zig`：本轮完成 domain / adapter 分层

## Conclusion

Candidate 6 到当前收益边界。后续不再做机械 test 瘦身，除非新增 adapter interface 明显变宽。
