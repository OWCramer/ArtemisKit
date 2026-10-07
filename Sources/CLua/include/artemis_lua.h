// Shiori's bridge between Artemis scripts' Lua and the Swift interpreter: the engine
// object `e` that Lua functions receive (`function f(e, param)`), file reads redirected
// to the game's archives, and a few calls the Swift side makes into Lua.
#pragma once
#include <stddef.h>
#include "lua.h"

typedef struct ArtemisLuaHost {
    void *context;
    /// e:tag{"name", key=value, ...}. Keys and values are NUL-terminated byte strings.
    void (*tag)(void *context, const char *name, int count, const char *const *keys, const char *const *values);
    /// e:var(name). Returns a malloc'd string the bridge frees, or NULL when unset.
    char *(*var)(void *context, const char *name);
    /// e:debug(message)
    void (*debug)(void *context, const char *message);
    /// A file from the game (archives, loose, patch). malloc'd, or NULL when missing.
    char *(*read_file)(void *context, const char *path, size_t *length);
    /// e:getScriptStack(): malloc'd "file\tindex\n" lines, innermost first.
    char *(*script_stack)(void *context);
    /// A method of `e` Shiori doesn't implement yet was called.
    void (*unsupported)(void *context, const char *method);
    /// e:getMousePoint(): the last pointer/touch position in stage pixels.
    void (*mouse_point)(void *context, double *x, double *y);
    /// e:setEventHandler{event = "function"}: "" clears.
    void (*set_event_handler)(void *context, const char *event, const char *function);
    /// Everything else the `e` object asks the engine (see LUA_PRELUDE in artemis_lua.c):
    /// `name` plus string arguments; returns a malloc'd answer, or NULL for nil.
    char *(*query)(void *context, const char *name, int count, const char *const *args, size_t *length);
} ArtemisLuaHost;

/// A Lua 5.1 state with the standard libraries, `e`, and the archive-backed io.open.
/// `host` must outlive the state.
lua_State *artemis_lua_open(const ArtemisLuaHost *host);
void artemis_lua_close(lua_State *L);

/// Sets a global number (sc_width, sc_height, ...).
void artemis_lua_set_number(lua_State *L, const char *name, double value);

/// Runs a chunk. Returns NULL, or a malloc'd error message.
char *artemis_lua_run(lua_State *L, const char *code, size_t length, const char *chunk_name);

/// Calls global (dotted names allowed) `function(e, param)` with `param` built from the
/// pairs. Returns NULL, or a malloc'd error message.
char *artemis_lua_call(lua_State *L, const char *function, int count, const char *const *keys, const char *const *values);

/// True when a global function by that (dotted) name exists.
int artemis_lua_has_function(lua_State *L, const char *function);

/// The `e:setTagFilter` function for tag `name`, called with the tag's parameters:
/// -1 when there's none, 1 when it handled the tag (skip it), 0 to run the tag. On a Lua
/// error, sets `*error` (malloc'd) and returns 0.
int artemis_lua_filter_tag(lua_State *L, const char *name, int count, const char *const *keys, const char *const *values, char **error);

/// Runs the function set by e:setEventFilter with (e, tagName, param): 0 continue,
/// 1 handled, 2 failed; -1 when there's no filter. Errors set `*error` (malloc'd), return 0.
int artemis_lua_filter_event(lua_State *L, const char *name, int count, const char *const *keys, const char *const *values, char **error);
