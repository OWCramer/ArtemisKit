# CLua

Lua 5.1.5 from https://www.lua.org/ftp/lua-5.1.5.tar.gz (SHA-256 2640fc56a795f29d28ef15e13c34a47e223960b0240e8cb0a82d9b0738695333), MIT licence (COPYRIGHT). Artemis games of the older generation are written against Lua 5.1 (e.g. `string.gfind`).

Changes: `lua.c`, `luac.c` and `print.c` dropped; public headers moved to `include/`; `os.execute` returns -1 instead of calling `system()` (unavailable on iOS). `artemis_lua.c` is Shiori's bridge for the engine's `e` object.
