Title: 定义 SnapWordIterator 纯逻辑接口
Status: ready-for-agent

## What to build

为 selection word snap 引入一个 Zig 内部 `SnapWordIterator` interface，让 Zig 持有完整迭代状态和停止条件，C 只保留 glyph、line length 和 wrap 事实读取。这个 slice 只交付纯逻辑和测试，不改 `st.c` 的运行路径。

## Acceptance criteria

- [ ] Zig 内部新增 iterator state、reader snapshot 和 iter result 类型，能够表达 word snap 的完整多步迭代
- [ ] 现有 delimiter break、line end、wrap stop 语义被保留，并由新的纯逻辑测试覆盖
- [ ] 旧 `snapWordLoopStep` 如暂时保留，只作为过渡层复用新逻辑，不新增更宽的 ABI surface

## Blocked by

None - can start immediately
