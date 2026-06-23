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
    Parse --> Handle[st.c csihandle]
    Handle --> Cursor[st_cursor.zig CursorCommand]
    Handle --> Edit[st_edit.zig EditCommand / LineRegion]
    Handle --> Erase[st_erase.zig EraseCommand]
    Handle --> Mode[st_mode.zig ModeParam]
    Handle --> State[st_state.zig CsiCommand / Resize / Reset]
    Handle --> Attr[st_attr.zig SgrParams / AttrUpdate]
    Handle --> Misc[st_misc.zig MiscCommand]
    Cursor --> CExec[st.c executor]
    Edit --> CExec
    Erase --> CExec
    Mode --> CExec
    State --> CExec
    Attr --> CExec
    Misc --> CExec
    CExec --> Effects[tmoveto / tclearregion / xsetmode / ttywrite / redraw]
```

## Search 子系统流程

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
    Resize[tresize] --> ResizePlan[st_state.zig ResizeRequest]
    ResizePlan --> CResize[st.c realloc/free line/alt/hist/tabs]
    CResize --> ClearPlan[st_state.zig ResizeClear]
    ClearPlan --> CClear[st.c tclearregion]

    Draw[draw] --> SearchScanGate[st_cursor.zig draw search gate]
    SearchScanGate --> SearchScan[searchscan]
    Draw --> CursorPlan[st_cursor.zig DrawCursor]
    CursorPlan --> DrawRegion[drawregion]
    DrawRegion --> DirtyGate[st_cursor.zig draw region dirty gate]
    DirtyGate --> XDraw[xdrawline]
    Draw --> CursorActive[st_cursor.zig cursor active gate]
    CursorActive --> XCursor[xdrawcursor]
    Draw --> ImeSpot[st_cursor.zig IME spot update gate]
    ImeSpot --> XXim[xximspot]
```

## 后续迁移路线图

```mermaid
flowchart LR
    A[Search 旧 adapter 已清理] --> C[Selection snap step 已 union 化]
    C --> D[Resize 循环范围 plan 化]
    D --> E[Draw/dirty range plan 收敛]
    E --> F[删除无用 ABI 符号]
    F --> G[补启动冒烟验证]
```

- **Search 清理**：旧 `st_search*plan` 兼容入口已删除，C 侧保留 `CursorEdit`、`StateEdit`、`MatchAppend` 和实际仍调用的 plan 入口。
- **Selection 提升**：line snap step 和 word snap loop step 已改成 tagged union，旧 word snap 辅助 ABI 已清理；C 保留 `TLINE` 访问和 delimiter 判断。
- **Resize 提升**：tab 初始化、history 新列填充、line resize 和新行分配范围已迁移为 Zig plan；C 继续执行 `xrealloc/free`。
- **Draw 收敛**：继续把 draw region 的范围、dirty line 决策聚合，C 继续调用 `xdrawline/xdrawcursor/xximspot`。
- **验证要求**：每批迁移后执行 `zig fmt`、`zig build abi-check`、`zig build test`、`zig build`；提交或发布前补 `timeout 5 ./zig-out/bin/st`。
