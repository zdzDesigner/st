# 架构流程图

本文档补充 `docs/zig-architecture.md`：前者描述边界规则，本文描述主要流程、模块关系和后续迁移路线。

## C/Zig 边界总览

```mermaid
flowchart LR
    Input[PTY / X11 / 用户输入] --> C[st.c executor]
    C --> State[term / sel / search 全局状态]
    C --> SideEffects[X11 / PTY / clipboard / IO / malloc / memmove]
    C --> H[st_zig.h C ABI]
    H --> Adapter[Zig export adapter]
    Adapter --> Domain[Zig domain modules]
    Domain --> Plan[plan / parse / decision / value object]
    Plan --> Adapter
    Adapter --> H
    H --> C

    classDef c fill:#f6d365,stroke:#9a6b00,color:#111;
    classDef zig fill:#b8e1ff,stroke:#1b5e8a,color:#111;
    class C,State,SideEffects c;
    class H,Adapter,Domain,Plan zig;
```

- C 侧持有全局状态和实际副作用，包括 `term`、`sel`、`search`、X11、PTY、clipboard、IO、内存所有权和 `TLINE(...)` 数组访问。
- Zig 侧只接收显式值、指针切片或 extern struct，返回可测试 plan；内部模块不读取 C 全局变量。
- `st_zig.h` 是唯一公开 ABI，`zig build abi-check` 校验 Zig `export fn st_*` 与头文件声明一致。

## 模块关系图

```mermaid
flowchart TB
    C[st.c]
    H[st_zig.h]
    Build[build.zig abi-check/test]

    C --> H
    Build --> H

    H --> Line[st_line.zig adapter]
    H --> Attr[st_attr.zig]
    H --> SetChar[st_setchar.zig]
    H --> Cursor[st_cursor.zig]
    H --> Edit[st_edit.zig]
    H --> State[st_state.zig]
    H --> Mode[st_mode.zig]
    H --> Misc[st_misc.zig]
    H --> CSI[st_csi.zig]
    H --> UTF8[st_utf8.zig]
    H --> Base64[st_base64.zig]
    H --> Str[st_strparse.zig / st_strhandle.zig]

    Line --> LineCore[st_line_core.zig]
    Line --> Selection[st_selection.zig]
    Line --> Search[st_search.zig]
    SetChar --> ControlEsc[st_control_esc.zig]
    SetChar --> Model[term_model.zig]
    LineCore --> Model
    Selection --> Model
    Search --> Model
    Cursor --> Model

    classDef c fill:#f6d365,stroke:#9a6b00,color:#111;
    classDef abi fill:#ddd,stroke:#666,color:#111;
    classDef zig fill:#b8e1ff,stroke:#1b5e8a,color:#111;
    class C c;
    class H,Build abi;
    class Line,Attr,SetChar,Cursor,Edit,State,Mode,Misc,CSI,UTF8,Base64,Str,LineCore,Selection,Search,ControlEsc,Model zig;
```

## 输入处理流程

```mermaid
flowchart TD
    Read[twrite / tputc] --> Decode[st_putc_decode.zig RuneInput]
    Decode --> Control{control?}
    Control -->|是| ControlExec[st_control_esc.zig ControlSequence]
    ControlExec --> CControl[st.c 执行 tab/backspace/linefeed/bell/str start]
    Control -->|否| Esc{ESC/STR active?}
    Esc -->|STR| Collect[st_setchar.zig StringCollector]
    Collect --> CString[st.c 扩容/strhandle]
    Esc -->|ESC| EscFlow[st_setchar.zig EscFlow + st_control_esc.zig EscSequence]
    EscFlow --> CEsc[st.c 执行 CSI/charset/test/reset 等副作用]
    Esc -->|普通字符| Prepare[st_setchar.zig PutcPrepare]
    Prepare --> Write[st_setchar.zig GlyphLine.putcWrite]
    Write --> CWrite[st.c 更新 cursor/line/dirty/selection]
```

## CSI/ESC 处理流程

```mermaid
flowchart TD
    Raw[ESC/CSI bytes] --> Parse[st_csi.zig CsiParser]
    Parse --> Plan[st_csi.zig CsiExecPlan]
    Plan --> Handle[st.c csihandle]
    Plan --> Cursor[cursor/edit/erase/state/light/misc 子 plan]
    Handle --> CExec[st.c executor]
    CExec --> Effects[tmoveto / tclearregion / xsetmode / ttywrite / redraw]
```

当前状态：`csihandle()` 已收敛为单一 `st_csiexecplan()` 顶层 command plan；C 侧只按 command kind 执行 `tapply*`、`tsetmode`、`tsetattr` 和 `xsetcursor` 等副作用。旧 `st_plancursor`、`st_planedit`、`st_planerase`、`st_planlight`、`st_planstate`、`st_planmisc` ABI 已删除。

## Search 子系统流程

当前状态：主流程完成，后续只做局部优化或无用 ABI 删除。C 侧保留搜索扫描所需的 `TLINE(...)` 读取、匹配数组写入、输入缓冲区内存移动和 redraw/free 等副作用；Zig 侧负责输入编辑、扫描范围、match append、current/jump 和状态动作计划。

```mermaid
flowchart TD
    Prompt[searchprompt] --> PromptPlan[st_search.zig PromptPlan]
    PromptPlan --> CAlloc[st.c 可选 xmalloc]

    Input[searchinput text] --> InsertPlan[st_search.zig InsertPlan]
    InsertPlan -->|grow| CRealloc[st.c xrealloc]
    InsertPlan --> CMove[st.c memmove/memcpy]
    CMove --> SearchSet[searchset]

    CursorKeys[backspace/delete/move/home/end] --> CursorEdit[st_search.zig CursorEdit union]
    CursorEdit --> ApplyEdit[st.c searchapplyedit]
    ApplyEdit -->|delete| CDelete[st.c searchdelete memmove]
    ApplyEdit -->|move| CCursor[更新 search.inputcursor]
    CDelete --> SearchSet
    CCursor --> Redraw[redraw]

    StateKeys[clear/commit/cancel] --> StateEdit[st_search.zig StateEdit union]
    StateEdit --> ApplyState[st.c searchapplystateedit]
    ApplyState -->|clear_input| SearchSet
    ApplyState -->|commit_set| SearchSet
    ApplyState -->|commit_clear| SearchClear[searchclear free/reset]
    ApplyState -->|cancel| Redraw

    SearchSet --> DecodeQuery[st.c utf8decode query]
    DecodeQuery --> SetPlan[st_search.zig SetPlan]
    SetPlan --> Scan[searchscan]
    Scan --> LineMatch[st_search.zig LineMatcher]
    LineMatch --> Append[st_search.zig MatchAppend union]
    Append -->|grow_append| MatchRealloc[st.c xrealloc matches]
    Append --> MatchWrite[st.c 写 SearchMatch]
    MatchWrite --> MatchList[st_search.zig MatchList slice]
    MatchList --> DrawHit[searchmatch/searchcurrent]
```

## Selection 子系统流程

当前状态：主流程完成，后续只做局部优化或无用 ABI 删除。C 侧保留 selection 全局状态写回、`TLINE(...)` glyph 读取、delimiter 判断、clipboard 文本分配和 UTF-8 编码；Zig 侧负责 normalize、extend、scroll、snap step、选中判断和 getsel 行范围计划。

```mermaid
flowchart TD
    Start[selstart] --> StartPlan[st_selection.zig startPlan]
    Extend[selextend] --> ExtendPlan[st_selection.zig extendPlan]
    Scroll[selscroll] --> ScrollPlan[st_selection.zig scrollPlan]
    Normalize[selnormalize] --> Bounds[st_selection.zig normalize / normalizeColumns]
    Snap[selsnap] --> SnapPlan[st_selection.zig snapWordPlan / snapWordStep / snapLineX]
    GetSel[getsel] --> GetLine[st_selection.zig getLinePlan / newline / buffer size]

    StartPlan --> CState[st.c 更新 sel]
    ExtendPlan --> CState
    ScrollPlan --> CState
    Bounds --> CState
    SnapPlan --> CTLine[st.c 读取 TLINE 和 word delimiter]
    GetLine --> CCopy[st.c utf8encode / malloc / 返回 selection 文本]
```

## Resize/Draw 流程

```mermaid
flowchart TD
    Resize[tresize] --> ResizePlan[st_state.zig ResizeExecPlan]
    ResizePlan --> SlideFree[st.c slide/free]
    SlideFree --> Realloc[st.c realloc containers]
    Realloc --> Hist[st.c hist resize/fill]
    Hist --> Rows[st.c line resize/alloc]
    Rows --> Tabs[st.c tabs]
    Tabs --> Clear[st.c tclearregion]

    Draw[draw] --> Frame[st_cursor.zig DrawFramePlan]
    Frame --> SearchScan[searchscan]
    Frame --> Region[drawregion]
    Region --> DirtyGate[st_cursor.zig DrawRegionPlan]
    DirtyGate --> XDraw[xdrawline]
    Frame --> XCursor[xdrawcursor]
    Frame --> ImeSpot[xximspot]
    ImeSpot --> XXim[xximspot]
```

## Line/ExternalPipe 流程

```mermaid
flowchart TD
    Pipe[externalpipe] --> CLine[st.c tlinehist]
    CLine --> Plan[st_line.zig ExternalPipePlan]
    Plan --> CWrite[st.c utf8encode / xwrite]
    Plan --> Newline[st.c final newline]
```

当前状态：`externalpipe()` 已合并为单一 `st_externalpipeplan()`，Zig 同时规划行长度、输出范围和 wrap newline；C 侧保留历史/当前行指针获取、UTF-8 编码、pipe/fork/exec/xwrite 和 signal 处理。

## 后续迁移路线图

```mermaid
flowchart LR
    A[Search 旧 adapter 已清理] --> C[Selection snap step 已 union 化]
    C --> D[Resize 循环范围 plan 化]
    D --> E[Draw/dirty range plan 收敛]
    E --> F[删除无用 ABI 符号]
    F --> G[补启动冒烟验证]
```

- **Search 定版**：主流程完成，旧 `st_search*plan` 兼容入口和测试专用 ABI 已删除；C 侧只保留扫描所需 `TLINE(...)`、匹配数组写入、输入缓冲区移动和 redraw/free 等副作用。
- **Selection 定版**：主流程完成，line snap step 和 word snap loop step 已 plan 化；C 侧只保留 `TLINE(...)` glyph 读取、delimiter 判断、selection 全局状态写回和 clipboard 文本输出。
- **Resize 收口**：`tresize` 已按 `ZigResizeExecPlan` 执行 slide/free、container realloc、hist resize/fill、line resize/alloc、tabs 和 clear；C 继续执行 `xrealloc/free/memmove/xmalloc/memset/tclearregion`。
- **Draw 收口**：draw frame gate、cursor 调整和 draw region dirty 扫描已迁移为 Zig plan；C 侧只表达 `xstartdraw`、searchscan、drawregion、cursor、IME 和 `xfinishdraw` 副作用链。
- **CSI 聚合**：`csihandle` 已改为 `ZigCsiExecPlan` 顶层分发，六个旧 `st_plan*` 小 ABI 已删除；C 继续执行真实副作用。
- **ExternalPipe 聚合**：行长度、write/skip、lastpos 和 wrap newline 已合并为 `st_externalpipeplan`；C 继续负责 `tlinehist`、`utf8encode` 和 `xwrite`。
- **ABI 瘦身**：`st_zig.h` 只保留 C executor 实际调用入口；仅 Zig 测试引用的 export 应删除，测试改测内部领域函数。
- **验证要求**：每批迁移后执行 `zig fmt`、`zig build abi-check`、`zig build test`、`zig build`；提交或发布前补 `timeout 5 ./zig-out/bin/st`。
