## suckless st 
*fork [LukeSmithxyz](https://github.com/LukeSmithxyz/st)* 
- spersonalize conf and as a backup


### relativity
> shell script link to [cliconf](https://github.com/zdzDesigner/cliconf)

### Zig migration

This fork builds `st` as a C/Zig hybrid. C keeps executor responsibilities such as X11, PTY, clipboard, IO, global terminal state, and actual side effects. Zig carries pure planning and parsing logic behind the C ABI bridge in `st_zig.h`.

Architecture notes: `docs/zig-architecture.md`.

Common checks:

```sh
zig build abi-check
zig build test
zig build
timeout 5 ./zig-out/bin/st
```
