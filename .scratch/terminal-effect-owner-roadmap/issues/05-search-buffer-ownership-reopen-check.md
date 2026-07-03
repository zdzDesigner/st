Title: search buffer ownership reopen check
Status: ready-for-agent
Progress: todo

## Goal

复查 Search owner 的 query/input/matches buffer ownership 是否仍应保持 C 持有，或是否出现新的可验证迁移切片。

## Scope

- `searchset()` query replace transaction
- `searchinput()` input mutation transaction
- `searchapplymatchestransaction()` / `searchscanline()` matches write path
- `searchjump()` / `searchapplyvieweffect()` redraw and scroll effects

## Boundary

- 不迁移 `Rune *query`、`char *input`、`SearchMatch *matches` ownership，除非本 issue 先证明收益和验证路径。
- 不把 realloc/memmove/memcpy/free 搬入 Zig。

## Dependencies

- `01-owner-roadmap-freeze`

## Blocked by

- `.scratch/terminal-effect-owner-roadmap/issues/01-owner-roadmap-freeze.md`

## Acceptance criteria

- [ ] 复核当前 search buffer ownership 决策是否仍成立。
- [ ] 如果继续保持 C ownership，记录理由和 reopen 条件。
- [ ] 如果存在安全切片，新增具体 AFK issue。

## Validation

- `zig build abi-check`
- `zig build test`
- `zig build`

## Comments

