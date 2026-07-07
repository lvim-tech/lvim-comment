-- lvim-comment: comment toggling with operators, counts and dot-repeat.
-- Replaces Neovim's built-in linewise `gc` mappings (config-gated) so that linewise and
-- blockwise commenting share ONE engine and ONE commentstring resolver: `gc{motion}` /
-- `gcc` / visual `gc` toggle lines, `gb{motion}` / `gbb` / visual `gb` toggle a block
-- comment (a same-line charwise region becomes a true inline block comment). The
-- operator is a plain 'operatorfunc' behind `g@`, so counts (`3gcc`) and dot-repeat come
-- from Vim itself — a count typed before an expr mapping stays pending and applies to
-- the returned keys, and `.` re-fires `g@` with the same motion; no key replay, no
-- count bookkeeping. The commentstring is resolved per POSITION (config override →
-- treesitter language at the range start → 'commentstring'), so embedded languages
-- (lua-in-markdown, css-in-html, jsx) get their own markers. The built-in o-mode `gc`
-- (comment-lines textobject) is deliberately left alone — it composes with any operator
-- (`dgc`, `ygc`) and does not overlap with the operator mappings here.
--
---@module "lvim-comment"

local api = vim.api
local config = require("lvim-comment.config")
local cstring = require("lvim-comment.cstring")
local engine = require("lvim-comment.engine")
local extra = require("lvim-comment.extra")

local ok_utils, utils = pcall(require, "lvim-utils.utils")

local M = {}

-- Operator state between the expr mapping (which arms 'operatorfunc' and returns `g@`)
-- and the opfunc call: which engine to run and, with `sticky`, where to put the cursor
-- back. On dot-repeat only the opfunc runs, so `kind` persists (the repeat re-runs the
-- last operator) while `cursor` is nil — Vim then leaves the cursor at the range start.
---@type { kind: "line"|"block", cursor: integer[]|nil }
local state = { kind = "line", cursor = nil }

--- Report a resolution failure without breaking the mapping flow.
---@param msg string
---@return nil
local function warn(msg)
    vim.notify("lvim-comment: " .. msg, vim.log.levels.WARN)
end

--- Resolve the commentstring pair at the range's first non-blank position — that is
--- where the embedded language actually is (a leading blank line belongs to no
--- injection region).
---@param bufnr integer
---@param s integer  1-based first line of the range
---@param lines string[]  the range's lines (already fetched)
---@return LvimCommentPair|nil
local function resolve_at(bufnr, s, lines)
    local row, col = s - 1, 0
    for i, line in ipairs(lines) do
        local c = line:find("%S")
        if c then
            row, col = s - 1 + i - 1, c - 1
            break
        end
    end
    return cstring.resolve(bufnr, { row, col })
end

--- Toggle LINE comments on an inclusive 1-based line range (public API — other plugins
--- can call it directly). All non-blank lines commented → uncomment; otherwise comment.
---@param s integer  first line (1-based, inclusive)
---@param e integer  last line (1-based, inclusive)
---@param bufnr? integer  buffer (nil/0: current)
---@return nil
function M.toggle_lines(s, e, bufnr)
    if bufnr == nil or bufnr == 0 then
        bufnr = api.nvim_get_current_buf()
    end
    if s > e then
        s, e = e, s
    end
    local lines = api.nvim_buf_get_lines(bufnr, s - 1, e, false)
    if #lines == 0 then
        return
    end
    local pair = resolve_at(bufnr, s, lines)
    local cs = pair and (pair.line or pair.block)
    if not cs then
        warn("no commentstring for this position")
        return
    end
    api.nvim_buf_set_lines(bufnr, s - 1, e, false, (engine.toggle_line(lines, cs, config.padding)))
end

--- Toggle a BLOCK comment around an inclusive 1-based line range. Falls back to the
--- linewise toggle when the language has no block form (python, yaml, …) — every line
--- still ends up commented/uncommented, which is the correct degradation.
---@param s integer  first line (1-based, inclusive)
---@param e integer  last line (1-based, inclusive)
---@param bufnr? integer  buffer (nil/0: current)
---@return nil
function M.toggle_block(s, e, bufnr)
    if bufnr == nil or bufnr == 0 then
        bufnr = api.nvim_get_current_buf()
    end
    if s > e then
        s, e = e, s
    end
    local lines = api.nvim_buf_get_lines(bufnr, s - 1, e, false)
    if #lines == 0 then
        return
    end
    local pair = resolve_at(bufnr, s, lines)
    local cs = pair and pair.block
    if not cs or select(2, engine.parts(cs)) == "" then
        return M.toggle_lines(s, e, bufnr)
    end
    api.nvim_buf_set_lines(bufnr, s - 1, e, false, (engine.toggle_block(lines, cs, config.padding)))
end

--- Toggle an INLINE block comment around a same-line charwise region (from the `'[`/`']`
--- operator marks). Falls back to a linewise toggle of that line when the language has
--- no block form.
---@param bufnr integer
---@param row integer  1-based line
---@param scol0 integer  0-based start byte column (`'[` mark)
---@param ecol0 integer  0-based end byte column (`']` mark — the last char's FIRST byte)
---@return nil
local function toggle_inline(bufnr, row, scol0, ecol0)
    local line = api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ""
    if line == "" then
        return
    end
    local scol = math.min(scol0 + 1, #line)
    local ecol = math.min(ecol0 + 1, #line)
    -- The `']` mark points at the last character's first byte; extend to the full UTF-8
    -- sequence so a multibyte character is never split.
    local ch = line:sub(ecol):match("^[%z\1-\127\194-\244][\128-\191]*")
    if ch and #ch > 0 then
        ecol = ecol + #ch - 1
    end
    local pair = cstring.resolve(bufnr, { row - 1, scol - 1 })
    local cs = pair and pair.block
    if not cs or select(2, engine.parts(cs)) == "" then
        return M.toggle_lines(row, row, bufnr)
    end
    api.nvim_buf_set_lines(bufnr, row - 1, row, false, { (engine.toggle_inline(line, scol, ecol, cs, config.padding)) })
end

--- Resolve the effective commentstring pair at a position (public — other plugins may
--- query it; see |lvim-comment-resolution| for the order).
---@param bufnr? integer  buffer (nil/0: current)
---@param pos? integer[]  { row0, col0 }; default: the cursor
---@return LvimCommentPair|nil
function M.resolve(bufnr, pos)
    return cstring.resolve(bufnr, pos)
end

--- Expr-mapping entry: arm the operator. Returns `g@` so the following motion (or the
--- visual selection, when invoked from an x-mapping — `g@` in visual mode operates on
--- it directly) drives the opfunc.
---@param kind "line"|"block"
---@return string  keys for the expr mapping
function M.operator(kind)
    state.kind = kind
    state.cursor = config.sticky and api.nvim_win_get_cursor(0) or nil
    vim.o.operatorfunc = "v:lua.require'lvim-comment'.opfunc"
    return "g@"
end

--- Expr-mapping entry for the current line (`gcc` / `gbb`): `g@_` — the pending count
--- applies to the `_` motion natively, so `3gcc` covers 3 lines.
---@param kind "line"|"block"
---@return string  keys for the expr mapping
function M.current(kind)
    return M.operator(kind) .. "_"
end

--- 'operatorfunc' target (dispatched via v:lua). Reads the operator marks and runs the
--- armed engine; a blockwise operator over a same-line charwise motion becomes an
--- inline block comment, anything else works on whole lines.
---@param motion "line"|"char"|"block"
---@return nil
function M.opfunc(motion)
    local bufnr = api.nvim_get_current_buf()
    local s = api.nvim_buf_get_mark(bufnr, "[")
    local e = api.nvim_buf_get_mark(bufnr, "]")
    if s[1] == 0 or e[1] == 0 or e[1] < s[1] then
        return
    end
    if state.kind == "block" and motion == "char" and s[1] == e[1] then
        toggle_inline(bufnr, s[1], s[2], e[2])
    elseif state.kind == "block" then
        M.toggle_block(s[1], e[1], bufnr)
    else
        M.toggle_lines(s[1], e[1], bufnr)
    end
    if state.cursor then
        pcall(api.nvim_win_set_cursor, 0, state.cursor)
        state.cursor = nil
    end
end

--- Define the <Plug> surface and (config-gated) the default keys. The global `gc` set
--- REPLACES Neovim's built-in linewise mappings — same keys, one engine for line and
--- block, one position-aware resolver.
---@return nil
local function set_mappings()
    local set = vim.keymap.set

    set("n", "<Plug>(lvim-comment-toggle-linewise)", function()
        return M.operator("line")
    end, { expr = true, desc = "Toggle comment (linewise operator)" })
    set("n", "<Plug>(lvim-comment-toggle-blockwise)", function()
        return M.operator("block")
    end, { expr = true, desc = "Toggle comment (blockwise operator)" })
    set("n", "<Plug>(lvim-comment-toggle-linewise-current)", function()
        return M.current("line")
    end, { expr = true, desc = "Toggle comment (line)" })
    set("n", "<Plug>(lvim-comment-toggle-blockwise-current)", function()
        return M.current("block")
    end, { expr = true, desc = "Toggle comment (block)" })
    set("x", "<Plug>(lvim-comment-toggle-linewise-visual)", function()
        return M.operator("line")
    end, { expr = true, desc = "Toggle comment (linewise)" })
    set("x", "<Plug>(lvim-comment-toggle-blockwise-visual)", function()
        return M.operator("block")
    end, { expr = true, desc = "Toggle comment (blockwise)" })
    set("n", "<Plug>(lvim-comment-insert-below)", extra.insert_below, { desc = "Commented line below (insert)" })
    set("n", "<Plug>(lvim-comment-insert-above)", extra.insert_above, { desc = "Commented line above (insert)" })
    set("n", "<Plug>(lvim-comment-insert-eol)", extra.insert_eol, { desc = "Append comment at EOL (insert)" })

    if config.mappings.basic then
        set("n", "gc", "<Plug>(lvim-comment-toggle-linewise)", { desc = "Toggle comment (linewise operator)" })
        set("n", "gb", "<Plug>(lvim-comment-toggle-blockwise)", { desc = "Toggle comment (blockwise operator)" })
        set("n", "gcc", "<Plug>(lvim-comment-toggle-linewise-current)", { desc = "Toggle comment (line)" })
        set("n", "gbb", "<Plug>(lvim-comment-toggle-blockwise-current)", { desc = "Toggle comment (block)" })
        set("x", "gc", "<Plug>(lvim-comment-toggle-linewise-visual)", { desc = "Toggle comment (linewise)" })
        set("x", "gb", "<Plug>(lvim-comment-toggle-blockwise-visual)", { desc = "Toggle comment (blockwise)" })
    end
    if config.mappings.extra then
        set("n", "gco", "<Plug>(lvim-comment-insert-below)", { desc = "Commented line below (insert)" })
        set("n", "gcO", "<Plug>(lvim-comment-insert-above)", { desc = "Commented line above (insert)" })
        set("n", "gcA", "<Plug>(lvim-comment-insert-eol)", { desc = "Append comment at EOL (insert)" })
    end
end

--- Configure lvim-comment: merge user opts into the live config, define the mappings
--- and the :LvimComment range command. Idempotent — re-running redefines the same maps.
---@param opts? LvimCommentConfig
---@return nil
function M.setup(opts)
    -- Merge user overrides into the live config in place (readers see them through
    -- require). The shared merge clean-REPLACES arrays; the fallback only runs when
    -- lvim-utils is absent.
    if ok_utils and utils.merge then
        utils.merge(config, opts or {})
    elseif opts then
        for k, v in pairs(opts) do
            if type(v) == "table" and type(config[k]) == "table" then
                config[k] = vim.tbl_deep_extend("force", config[k], v)
            else
                config[k] = v
            end
        end
    end

    set_mappings()

    api.nvim_create_user_command("LvimComment", function(cmd)
        if cmd.args == "block" then
            M.toggle_block(cmd.line1, cmd.line2)
        else
            M.toggle_lines(cmd.line1, cmd.line2)
        end
    end, {
        range = true,
        nargs = "?",
        complete = function()
            return { "line", "block" }
        end,
        desc = "Toggle comments over the range (line|block)",
    })
end

return M
