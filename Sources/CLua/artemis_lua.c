// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

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

// e:random([n]): 0..n-1, or without n a whole number 0..2^31-1 (games index with
// `e:random() % m + 1`: NUKITASHI's system voices, Memory's Dogma's screen shakes).
static int e_random(lua_State *L) {
    if (lua_gettop(L) >= 2 && lua_isnumber(L, 2)) {
        lua_Integer n = lua_tointeger(L, 2);
        lua_pushinteger(L, n > 0 ? (lua_Integer)(arc4random_uniform((unsigned)n)) : 0);
    } else {
        lua_pushinteger(L, (lua_Integer)(arc4random() & 0x7FFFFFFF));
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

// e:getMousePoint() -> {x=, y=}
static int e_get_mouse_point(lua_State *L) {
    const ArtemisLuaHost *host = host_of(L);
    double x = 0, y = 0;
    host->mouse_point(host->context, &x, &y);
    lua_newtable(L);
    lua_pushnumber(L, x);
    lua_setfield(L, -2, "x");
    lua_pushnumber(L, y);
    lua_setfield(L, -2, "y");
    return 1;
}

// e:setEventHandler{onEnterFrame = "f", onClickWaitIn = "g", ...}
static int e_set_event_handler(lua_State *L) {
    luaL_checktype(L, 2, LUA_TTABLE);
    const ArtemisLuaHost *host = host_of(L);
    lua_pushnil(L);
    while (lua_next(L, 2) != 0) {
        if (lua_type(L, -2) == LUA_TSTRING) {
            const char *function = lua_isstring(L, -1) ? lua_tostring(L, -1) : "";
            host->set_event_handler(host->context, lua_tostring(L, -2), function);
        }
        lua_pop(L, 1);
    }
    return 0;
}

static const char *FILTER_KEY = "artemis.tagfilter";

// e:setTagFilter{name = function(e, param) ... end, ...}: runs before each tag of that name.
static int e_set_tag_filter(lua_State *L) {
    if (lua_istable(L, 2)) lua_pushvalue(L, 2); else lua_pushnil(L);
    lua_setfield(L, LUA_REGISTRYINDEX, FILTER_KEY);
    return 0;
}

// e:file(path) -> the file's contents (archives included), or nil.
static int e_file(lua_State *L) {
    const ArtemisLuaHost *host = host_of(L);
    size_t length = 0;
    char *data = host->read_file(host->context, luaL_checkstring(L, 2), &length);
    if (!data) {
        lua_pushnil(L);
        return 1;
    }
    lua_pushlstring(L, data, length);
    free(data);
    return 1;
}

// __artemis_query(name, ...) -> string or nil: the generic channel the Lua prelude uses.
static int artemis_query(lua_State *L) {
    const ArtemisLuaHost *host = host_of(L);
    const char *name = luaL_checkstring(L, 1);
    int count = lua_gettop(L) - 1;
    const char **args = malloc(sizeof(char *) * (count > 0 ? count : 1));
    for (int i = 0; i < count; i++) {
        // tostring copies for numbers and booleans live on the stack until we return.
        if (lua_isboolean(L, i + 2)) {
            args[i] = lua_toboolean(L, i + 2) ? "1" : "0";
        } else {
            args[i] = lua_tostring(L, i + 2);
            if (!args[i]) args[i] = "";
        }
    }
    size_t length = 0;
    char *answer = host->query(host->context, name, count, args, &length);
    free(args);
    if (!answer) {
        lua_pushnil(L);
        return 1;
    }
    lua_pushlstring(L, answer, length);
    free(answer);
    return 1;
}

// The rest of the engine API, in Lua over __artemis_query. Fields are joined with \31
// (unit separator) and records with \30 (record separator).
static const char *LUA_PRELUDE =
    "local q = __artemis_query\n"
    "__artemis_query = nil\n"
    "local US, RS = string.char(31), string.char(30)\n"
    "local function split(s, sep)\n"
    "  local t = {}\n"
    "  if s == nil or s == '' then return t end\n"
    "  local start = 1\n"
    "  while true do\n"
    "    local i = string.find(s, sep, start, true)\n"
    "    if not i then table.insert(t, string.sub(s, start)); break end\n"
    "    table.insert(t, string.sub(s, start, i - 1)); start = i + 1\n"
    "  end\n"
    "  return t\n"
    "end\n"
    "local function pairsOf(record, from)\n"
    "  local f, t = split(record, US), {}\n"
    "  for i = from, #f - 1, 2 do t[f[i]] = f[i + 1] end\n"
    "  return t\n"
    "end\n"
    "local function encodeTag(t)\n"
    "  local parts = { tostring(t[1] or t[0] or '') }\n"
    "  for k, v in pairs(t) do\n"
    "    if type(k) == 'string' then table.insert(parts, k); table.insert(parts, tostring(v)) end\n"
    "  end\n"
    "  return table.concat(parts, US)\n"
    "end\n"
    "function e:now() return tonumber(q('now')) end\n"
    "function e:getFrameNumber() return tonumber(q('frame')) end\n"
    "function e:getScriptStatus() return tonumber(q('status')) end\n"
    "function e:setScriptStatus(n) q('setStatus', n) end\n"
    "function e:getScriptWaitReason()\n"
    "  local t = pairsOf(q('waitReason') or '', 1)\n"
    "  for k, v in pairs(t) do if k ~= 'sound' and k ~= 'video' then t[k] = tonumber(v) end end\n"
    "  return t\n"
    "end\n"
    "function e:isDown(k) return q('key', 'down', k) == '1' end\n"
    "function e:isDownEdge(k) return q('key', 'downEdge', k) == '1' end\n"
    "function e:isUpEdge(k) return q('key', 'upEdge', k) == '1' end\n"
    "function e:isPush(k) return q('key', 'push', k) == '1' end\n"
    "function e:isDecide(k) return q('key', 'decide', k) == '1' end\n"
    "function e:overrideKey(t) t = t or {}; q('overrideKey', t.key or '', t.status or '') end\n"
    "function e:getTouchCount() return tonumber(q('touchCount')) or 0 end\n"
    "function e:getTouchPoint()\n"
    "  local t = {}\n"
    "  for _, r in ipairs(split(q('touches') or '', RS)) do\n"
    "    local f = split(r, US)\n"
    "    t[tonumber(f[1])] = { x = tonumber(f[2]), y = tonumber(f[3]) }\n"
    "  end\n"
    "  return t\n"
    "end\n"
    "function e:getScriptBlock(t)\n"
    "  t = t or {}\n"
    "  local r = q('block', t.file or '', t.index or 0)\n"
    "  if not r then return nil end\n"
    "  local f = split(r, US)\n"
    "  return { command = f[1], line = tonumber(f[2]), parameter = pairsOf(r, 3) }\n"
    "end\n"
    "function e:getScriptSize(file) return tonumber(q('size', file or '')) end\n"
    "function e:setScriptStack(t)\n"
    "  local records = {}\n"
    "  local i = t[0] and 0 or 1\n"
    "  while t[i] do table.insert(records, tostring(t[i].file) .. US .. tostring(t[i].index)); i = i + 1 end\n"
    "  q('setStack', table.concat(records, RS))\n"
    "end\n"
    "function e:enqueueTag(t) q('enqueue', encodeTag(t)) end\n"
    "function e:isFileExists(p) return q('exists', p) == '1' end\n"
    "function e:convertEncoding(t) return t and t.source end\n"
    "function e:saveToMemory() return q('saveToMemory') end\n"
    "function e:loadFromMemory(s) q('loadFromMemory', s) end\n"
    "function e:loadPngComments(p) return pairsOf(q('pngComments', p) or '', 1) end\n"
    "function e:setMagicPath(t) q('magicPath', t[1] or '', t[2] or '') end\n"
    "function e:bindSurface(p) q('bindSurface', p) end\n"
    "function e:bindSurfaceAsync(p) q('bindSurface', p) end\n"
    "function e:unbindSurface(p) q('unbindSurface', p) end\n"
    "function e:isLoadingSurface(p) return false end\n"
    "function e:clearSurfaceLoadQueue() end\n"
    "function e:setEventFilter(f) __artemis_event_filter = f end\n"
    "function e:setLogFilter(f) __artemis_log_filter = f end\n"
    "function e:setUseMultiTouch(n) end\n"
    "function e:setUseTouchHold(b) q('touchHold', b) end\n"
    "function e:setFlickSensitivity(n) end\n"
    "function e:setUseGlobalCapture(b) end\n"
    "function e:writeClipboard(s) q('clipboard', s) end\n"
    "function e:callShellExecute(t) if t and t.file then q('openURL', t.file) end return 0 end\n"
    // Console capture rules, the debugger's skip, a Windows font cache and E-mote (none of
    // which exist here): harmless answers, so code that reaches them carries on.
    "function e:callOeAPI(t) return 0 end\n"
    "function e:debugSkip(t) end\n"
    "function e:restoreFontCache(p) end\n"
    "function e:getEmoteVersion() return 0 end\n"
    "function e:getEmoteLayer(t) return nil end\n"
    "function e:createEmoteLayer(t) return nil end\n"
    "function e:initNis(n) return true end\n"
    ;

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
/// `pluto` (Lua table persistence), which the newer generation saves its system, global and
/// config data and its saves with. The bytes only need to round-trip through Shiori, so this is
/// a small data-only format of its own (numbers, strings, booleans, tables, shared and cyclic
/// tables), read back without running any code.
static const char *PLUTO_PRELUDE =
    "pluto = {}\n"
    "function pluto.persist(perms, root)\n"
    "  local out, ids, n = {}, {}, 0\n"
    "  local function put(v)\n"
    "    local t = type(v)\n"
    "    if t == \"number\" then\n"
    "      if v ~= v then out[#out + 1] = \"nnan;\"\n"
    "      elseif v == math.huge then out[#out + 1] = \"ninf;\"\n"
    "      elseif v == -math.huge then out[#out + 1] = \"n-inf;\"\n"
    "      else out[#out + 1] = \"n\" .. string.format(\"%.17g\", v) .. \";\" end\n"
    "    elseif t == \"string\" then out[#out + 1] = \"s\" .. #v .. \":\" .. v\n"
    "    elseif t == \"boolean\" then out[#out + 1] = v and \"b1\" or \"b0\"\n"
    "    elseif t == \"table\" then\n"
    "      if ids[v] then out[#out + 1] = \"r\" .. ids[v] .. \";\" return end\n"
    "      n = n + 1\n"
    "      ids[v] = n\n"
    "      out[#out + 1] = \"t\"\n"
    "      for k, x in pairs(v) do\n"
    "        local kt, xt = type(k), type(x)\n"
    "        if (kt == \"number\" or kt == \"string\" or kt == \"boolean\" or kt == \"table\")\n"
    "          and (xt == \"number\" or xt == \"string\" or xt == \"boolean\" or xt == \"table\") then\n"
    "          put(k)\n"
    "          put(x)\n"
    "        end\n"
    "      end\n"
    "      out[#out + 1] = \"e\"\n"
    "    else out[#out + 1] = \"x\" end\n"
    "  end\n"
    "  put(root)\n"
    "  return table.concat(out)\n"
    "end\n"
    "function pluto.unpersist(perms, s)\n"
    "  if type(s) ~= \"string\" or s == \"\" then return nil end\n"
    "  local pos, tables = 1, {}\n"
    "  local get\n"
    "  get = function()\n"
    "    local c = string.sub(s, pos, pos)\n"
    "    pos = pos + 1\n"
    "    if c == \"n\" then\n"
    "      local e = string.find(s, \";\", pos, true)\n"
    "      local text = string.sub(s, pos, e - 1)\n"
    "      pos = e + 1\n"
    "      if text == \"nan\" then return 0 / 0 elseif text == \"inf\" then return math.huge elseif text == \"-inf\" then return -math.huge end\n"
    "      return tonumber(text)\n"
    "    elseif c == \"s\" then\n"
    "      local e = string.find(s, \":\", pos, true)\n"
    "      local len = tonumber(string.sub(s, pos, e - 1))\n"
    "      local v = string.sub(s, e + 1, e + len)\n"
    "      pos = e + 1 + len\n"
    "      return v\n"
    "    elseif c == \"b\" then\n"
    "      local v = string.sub(s, pos, pos) == \"1\"\n"
    "      pos = pos + 1\n"
    "      return v\n"
    "    elseif c == \"r\" then\n"
    "      local e = string.find(s, \";\", pos, true)\n"
    "      local id = tonumber(string.sub(s, pos, e - 1))\n"
    "      pos = e + 1\n"
    "      return tables[id]\n"
    "    elseif c == \"t\" then\n"
    "      local t = {}\n"
    "      tables[#tables + 1] = t\n"
    "      while string.sub(s, pos, pos) ~= \"e\" do\n"
    "        if pos > #s then error(\"pluto: truncated data\") end\n"
    "        local k = get()\n"
    "        local v = get()\n"
    "        if k ~= nil then t[k] = v end\n"
    "      end\n"
    "      pos = pos + 1\n"
    "      return t\n"
    "    elseif c == \"x\" then return nil end\n"
    "    error(\"pluto: bad data at \" .. (pos - 1))\n"
    "  end\n"
    "  local ok, v = pcall(get)\n"
    "  if ok then return v end\n"
    "  return nil\n"
    "end\n";

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

/// ARTEMIS_LUA_CALLS=1 (debugging): every Lua function call to stdout.
/// ARTEMIS_LUA_LINES=<file part>: every line run in matching chunks.
static void trace_calls(lua_State *L, lua_Debug *ar) {
    if (ar->event == LUA_HOOKLINE) {
        const char *filter = getenv("ARTEMIS_LUA_LINES");
        if (lua_getinfo(L, "S", ar) && filter && strstr(ar->short_src, filter)) {
            fprintf(stdout, "lua line %s:%d\n", ar->short_src, ar->currentline);
        }
        return;
    }
    if (getenv("ARTEMIS_LUA_CALLS") && lua_getinfo(L, "nS", ar) && ar->what[0] == 'L') {
        fprintf(stdout, "lua call %s (%s:%d)\n", ar->name ? ar->name : "?", ar->short_src, ar->linedefined);
    }
}

lua_State *artemis_lua_open(const ArtemisLuaHost *host) {
    lua_State *L = luaL_newstate();
    luaL_openlibs(L);
    if (getenv("ARTEMIS_LUA_CALLS") || getenv("ARTEMIS_LUA_LINES")) {
        lua_sethook(L, trace_calls, (getenv("ARTEMIS_LUA_CALLS") ? LUA_MASKCALL : 0) | (getenv("ARTEMIS_LUA_LINES") ? LUA_MASKLINE : 0), 0);
    }
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
        {"getMousePoint", e_get_mouse_point},
        {"setEventHandler", e_set_event_handler},
        {"setTagFilter", e_set_tag_filter},
        {"file", e_file},
        {NULL, NULL},
    };
    for (const luaL_Reg *m = methods; m->name; m++) {
        lua_pushcfunction(L, m->func);
        lua_setfield(L, -2, m->name);
    }
    static const char *unsupported[] = {
        NULL,
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
    if (luaL_loadstring(L, PLUTO_PRELUDE) == 0) lua_call(L, 0, 0);
    lua_pushcfunction(L, artemis_query);
    lua_setglobal(L, "__artemis_query");
    if (luaL_loadstring(L, LUA_PRELUDE) == 0) {
        lua_call(L, 0, 0);
    } else {
        host->debug(host->context, lua_tostring(L, -1));
        lua_pop(L, 1);
    }
    return L;
}

void artemis_lua_close(lua_State *L) {
    lua_close(L);
}

void artemis_lua_set_number(lua_State *L, const char *name, double value) {
    lua_pushnumber(L, value);
    lua_setglobal(L, name);
}

/// Error handler: the message with a Lua traceback (debug.traceback), so a failing call
/// says where in the game's scripts it came from.
static int add_traceback(lua_State *L) {
    lua_getglobal(L, "debug");
    if (!lua_istable(L, -1)) { lua_pop(L, 1); return 1; }
    lua_getfield(L, -1, "traceback");
    lua_remove(L, -2);
    if (!lua_isfunction(L, -1)) { lua_pop(L, 1); return 1; }
    lua_pushvalue(L, 1);
    lua_pushinteger(L, 2);
    lua_call(L, 2, 1);
    return 1;
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
    // The handler sits under the function and its two arguments.
    lua_pushcfunction(L, add_traceback);
    lua_insert(L, -4);
    int handler = lua_gettop(L) - 3;
    int status = lua_pcall(L, 2, 0, handler);
    lua_remove(L, handler);
    if (status != 0) return pop_error(L);
    return NULL;
}

int artemis_lua_filter_tag(lua_State *L, const char *name, int count, const char *const *keys, const char *const *values, char **error) {
    *error = NULL;
    lua_getfield(L, LUA_REGISTRYINDEX, FILTER_KEY);
    if (!lua_istable(L, -1)) {
        lua_pop(L, 1);
        return -1;
    }
    lua_getfield(L, -1, name);
    lua_remove(L, -2);
    if (!lua_isfunction(L, -1)) {
        lua_pop(L, 1);
        return -1;
    }
    lua_getglobal(L, "e");
    lua_newtable(L);
    for (int i = 0; i < count; i++) {
        lua_pushstring(L, values[i]);
        lua_setfield(L, -2, keys[i]);
    }
    if (lua_pcall(L, 2, 1, 0) != 0) {
        *error = pop_error(L);
        return 0;
    }
    int skip = lua_isnumber(L, -1) && lua_tonumber(L, -1) == 1;
    lua_pop(L, 1);
    return skip;
}

int artemis_lua_filter_event(lua_State *L, const char *name, int count, const char *const *keys, const char *const *values, char **error) {
    *error = NULL;
    lua_getglobal(L, "__artemis_event_filter");
    if (lua_isstring(L, -1) && !lua_isnumber(L, -1)) {
        // A function name rather than the function itself.
        const char *function = lua_tostring(L, -1);
        lua_pop(L, 1);
        push_dotted(L, function);
    }
    if (!lua_isfunction(L, -1)) {
        lua_pop(L, 1);
        return -1;
    }
    lua_getglobal(L, "e");
    lua_pushstring(L, name);
    lua_newtable(L);
    for (int i = 0; i < count; i++) {
        lua_pushstring(L, values[i]);
        lua_setfield(L, -2, keys[i]);
    }
    if (lua_pcall(L, 3, 1, 0) != 0) {
        *error = pop_error(L);
        return 0;
    }
    int result = lua_isnumber(L, -1) ? (int)lua_tonumber(L, -1) : 0;
    lua_pop(L, 1);
    return result;
}
