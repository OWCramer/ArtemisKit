#include "artemis_lua.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "lauxlib.h"
#include "lualib.h"

static const char *HOST_KEY = "artemis.host";

static const ArtemisLuaHost *host_of(lua_State *L) {
    lua_getfield(L, LUA_REGISTRYINDEX, HOST_KEY);
    const ArtemisLuaHost *host = lua_touserdata(L, -1);
    lua_pop(L, 1);
    return host;
}

/// A copy of the value at `index` as a tag attribute: numbers as Lua prints them,
/// booleans as 1/0, anything else empty. Caller frees.
static char *copy_value(lua_State *L, int index) {
    switch (lua_type(L, index)) {
    case LUA_TBOOLEAN:
        return strdup(lua_toboolean(L, index) ? "1" : "0");
    case LUA_TNUMBER: {
        lua_pushvalue(L, index); // convert a copy, never the iteration key
        char *copy = strdup(lua_tostring(L, -1));
        lua_pop(L, 1);
        return copy;
    }
    case LUA_TSTRING:
        return strdup(lua_tostring(L, index));
    default:
        return strdup("");
    }
}

static void free_pairs(int count, char **keys, char **values) {
    for (int i = 0; i < count; i++) {
        free(keys[i]);
        free(values[i]);
    }
    free(keys);
    free(values);
}

/// Copies the string-keyed pairs of the table at `table` (absolute index).
static int collect_pairs(lua_State *L, int table, char ***keys_out, char ***values_out) {
    int capacity = 16, count = 0;
    char **keys = malloc(sizeof(char *) * capacity);
    char **values = malloc(sizeof(char *) * capacity);
    lua_pushnil(L);
    while (lua_next(L, table) != 0) {
        if (lua_type(L, -2) == LUA_TSTRING) {
            if (count == capacity) {
                capacity *= 2;
                keys = realloc(keys, sizeof(char *) * capacity);
                values = realloc(values, sizeof(char *) * capacity);
            }
            keys[count] = strdup(lua_tostring(L, -2));
            values[count] = copy_value(L, -1);
            count++;
        }
        lua_pop(L, 1);
    }
    *keys_out = keys;
    *values_out = values;
    return count;
}

// e:tag{"name", key=value, ...}
static int e_tag(lua_State *L) {
    luaL_checktype(L, 2, LUA_TTABLE);
    const ArtemisLuaHost *host = host_of(L);
    lua_rawgeti(L, 2, 1);
    if (!lua_isstring(L, -1)) return luaL_error(L, "e:tag needs a tag name as its first element");
    char *name = strdup(lua_tostring(L, -1));
    lua_pop(L, 1);
    char **keys, **values;
    int count = collect_pairs(L, 2, &keys, &values);
    host->tag(host->context, name, count, (const char *const *)keys, (const char *const *)values);
    free_pairs(count, keys, values);
    free(name);
    return 0;
}

// e:var(name) -> string or nil
static int e_var(lua_State *L) {
    const char *name = luaL_checkstring(L, 2);
    const ArtemisLuaHost *host = host_of(L);
    char *value = host->var(host->context, name);
    if (value) {
        lua_pushstring(L, value);
        free(value);
    } else {
        lua_pushnil(L);
    }
    return 1;
}

// e:debug(message)
static int e_debug(lua_State *L) {
    const ArtemisLuaHost *host = host_of(L);
    host->debug(host->context, luaL_optstring(L, 2, ""));
    return 0;
}

static int load_file_chunk(lua_State *L, const char *path) {
    const ArtemisLuaHost *host = host_of(L);
    size_t length = 0;
    char *code = host->read_file(host->context, path, &length);
    if (!code) return luaL_error(L, "include: %s not found", path);
    int status = luaL_loadbuffer(L, code, length, path);
    free(code);
    if (status != 0) return lua_error(L);
    return 1;
}

// e:include(path): runs a Lua file from the game.
static int e_include(lua_State *L) {
    const char *path = luaL_checkstring(L, 2);
    load_file_chunk(L, path);
    lua_call(L, 0, 0);
    return 0;
}

// e:random([n]): 0..n-1 (or a float in [0,1) without n).
static int e_random(lua_State *L) {
    if (lua_gettop(L) >= 2 && lua_isnumber(L, 2)) {
        lua_Integer n = lua_tointeger(L, 2);
        lua_pushinteger(L, n > 0 ? (lua_Integer)(arc4random_uniform((unsigned)n)) : 0);
    } else {
        lua_pushnumber(L, (lua_Number)arc4random() / 4294967296.0);
    }
    return 1;
}

// e:getScriptStack() -> { {file=..., index=...}, ... }
static int e_get_script_stack(lua_State *L) {
    const ArtemisLuaHost *host = host_of(L);
    char *stack = host->script_stack(host->context);
    lua_newtable(L);
    if (!stack) return 1;
    int n = 1;
    char *line = stack, *next;
    while (line && *line) {
        next = strchr(line, '\n');
        if (next) *next = 0;
        char *tab = strchr(line, '\t');
        lua_newtable(L);
        if (tab) {
            *tab = 0;
            lua_pushstring(L, line);
            lua_setfield(L, -2, "file");
            lua_pushinteger(L, atoi(tab + 1));
            lua_setfield(L, -2, "index");
        }
        lua_rawseti(L, -2, n++);
        line = next ? next + 1 : NULL;
    }
    free(stack);
    return 1;
}

// Methods Shiori doesn't implement yet: note the call, return nil.
static int e_unsupported(lua_State *L) {
    const ArtemisLuaHost *host = host_of(L);
    host->unsupported(host->context, lua_tostring(L, lua_upvalueindex(1)));
    return 0;
}

// __artemis_read(path) -> contents or nil, for the io.open replacement.
static int artemis_read(lua_State *L) {
    const ArtemisLuaHost *host = host_of(L);
    size_t length = 0;
    char *data = host->read_file(host->context, luaL_checkstring(L, 1), &length);
    if (!data) {
        lua_pushnil(L);
        return 1;
    }
    lua_pushlstring(L, data, length);
    free(data);
    return 1;
}

// Read-only io.open over the game's files (archives included), as Artemis provides.
static const char *IO_PRELUDE =
    "local read = __artemis_read\n"
    "__artemis_read = nil\n"
    "io.open = function(path, mode)\n"
    "  if mode and (mode:find('w') or mode:find('a') or mode:find('+')) then return nil, path .. ': read-only' end\n"
    "  local s = read((path:gsub('\\\\', '/')))\n"
    "  if not s then return nil, path .. ': No such file or directory' end\n"
    "  local pos = 1\n"
    "  local f = {}\n"
    "  local function line()\n"
    "    if pos > #s then return nil end\n"
    "    local nl = s:find('\\n', pos, true)\n"
    "    local l\n"
    "    if nl then l = s:sub(pos, nl - 1); pos = nl + 1 else l = s:sub(pos); pos = #s + 1 end\n"
    "    return (l:gsub('\\r$', ''))\n"
    "  end\n"
    "  function f:lines() return line end\n"
    "  function f:read(format)\n"
    "    format = format or '*l'\n"
    "    if format == '*a' then local r = s:sub(pos); pos = #s + 1; return r end\n"
    "    if format == '*l' then return line() end\n"
    "    if type(format) == 'number' then local r = s:sub(pos, pos + format - 1); pos = pos + format; if r == '' then return nil end; return r end\n"
    "    return nil\n"
    "  end\n"
    "  function f:close() return true end\n"
    "  function f:seek() return pos - 1 end\n"
    "  return f\n"
    "end\n"
    "io.lines = function(path) local f = assert(io.open(path)); return f:lines() end\n";

lua_State *artemis_lua_open(const ArtemisLuaHost *host) {
    lua_State *L = luaL_newstate();
    luaL_openlibs(L);
    lua_pushlightuserdata(L, (void *)host);
    lua_setfield(L, LUA_REGISTRYINDEX, HOST_KEY);

    lua_newtable(L);
    static const luaL_Reg methods[] = {
        {"tag", e_tag},
        {"var", e_var},
        {"debug", e_debug},
        {"include", e_include},
        {"random", e_random},
        {"getScriptStack", e_get_script_stack},
        {NULL, NULL},
    };
    for (const luaL_Reg *m = methods; m->name; m++) {
        lua_pushcfunction(L, m->func);
        lua_setfield(L, -2, m->name);
    }
    static const char *unsupported[] = {
        "getScriptBlock", "setEventHandler", "enqueueTag", "setTagFilter", "file", "getMousePoint", NULL,
    };
    for (const char **name = unsupported; *name; name++) {
        lua_pushstring(L, *name);
        lua_pushcclosure(L, e_unsupported, 1);
        lua_setfield(L, -2, *name);
    }
    lua_setglobal(L, "e");

    lua_pushcfunction(L, artemis_read);
    lua_setglobal(L, "__artemis_read");
    if (luaL_loadstring(L, IO_PRELUDE) == 0) lua_call(L, 0, 0);
    return L;
}

void artemis_lua_close(lua_State *L) {
    lua_close(L);
}

void artemis_lua_set_number(lua_State *L, const char *name, double value) {
    lua_pushnumber(L, value);
    lua_setglobal(L, name);
}

static char *pop_error(lua_State *L) {
    const char *message = lua_tostring(L, -1);
    char *copy = strdup(message ? message : "(error without a message)");
    lua_pop(L, 1);
    return copy;
}

char *artemis_lua_run(lua_State *L, const char *code, size_t length, const char *chunk_name) {
    if (luaL_loadbuffer(L, code, length, chunk_name) != 0) return pop_error(L);
    if (lua_pcall(L, 0, 0, 0) != 0) return pop_error(L);
    return NULL;
}

/// Pushes the global at a dotted path (a.b.c), or nil.
static void push_dotted(lua_State *L, const char *path) {
    char *copy = strdup(path);
    char *part = strtok(copy, ".");
    lua_pushvalue(L, LUA_GLOBALSINDEX);
    while (part) {
        if (!lua_istable(L, -1)) {
            lua_pop(L, 1);
            lua_pushnil(L);
            break;
        }
        lua_getfield(L, -1, part);
        lua_remove(L, -2);
        part = strtok(NULL, ".");
    }
    free(copy);
}

int artemis_lua_has_function(lua_State *L, const char *function) {
    push_dotted(L, function);
    int is_function = lua_isfunction(L, -1);
    lua_pop(L, 1);
    return is_function;
}

char *artemis_lua_call(lua_State *L, const char *function, int count, const char *const *keys, const char *const *values) {
    push_dotted(L, function);
    if (!lua_isfunction(L, -1)) {
        lua_pop(L, 1);
        char message[512];
        snprintf(message, sizeof message, "calllua: no function %s", function);
        return strdup(message);
    }
    lua_getglobal(L, "e");
    lua_newtable(L);
    for (int i = 0; i < count; i++) {
        lua_pushstring(L, values[i]);
        lua_setfield(L, -2, keys[i]);
    }
    if (lua_pcall(L, 2, 0, 0) != 0) return pop_error(L);
    return NULL;
}
