-- lvim-comment.extra: the insert-mode entry points (gco / gcO / gcA).
-- Each resolves the commentstring AT THE CURSOR (so a gco inside a markdown lua fence
-- opens a `--` line, not an HTML one), writes the marker skeleton and enters insert
-- mode with the cursor in the content slot — between the left and right markers when
-- the commentstring has a closing side, appended at end-of-line otherwise.
--
---@module "lvim-comment.extra"

local api = vim.api
local config = require("lvim-comment.config")
local cstring = require("lvim-comment.cstring")
local engine = require("lvim-comment.engine")

local M = {}

--- Resolve the LINE markers at the cursor. `left` is nil (after a user-visible warning)
--- when nothing resolves — the caller then does nothing.
---@return string|nil left, string right, string pad
local function markers()
    local cur = api.nvim_win_get_cursor(0)
    local pair = cstring.resolve(nil, { cur[1] - 1, cur[2] })
    local cs = pair and (pair.line or pair.block)
    if not cs then
        vim.notify("lvim-comment: no commentstring for this position", vim.log.levels.WARN)
        return nil, "", ""
    end
    local l, r = engine.parts(cs)
    return l, r, config.padding and " " or ""
end

--- Place the cursor in the content slot of `text` (which ends with `pad .. right` when
--- `right` is non-empty) and enter insert mode there.
---@param row integer  1-based line the text was written to
---@param leftlen integer  byte length of everything before the content slot
---@param right string  the right marker ("" when none)
---@return nil
local function enter_insert(row, leftlen, right)
    api.nvim_win_set_cursor(0, { row, leftlen })
    if right == "" then
        vim.cmd.startinsert({ bang = true }) -- append at EOL
    else
        vim.cmd.startinsert() -- insert before the right marker's padding
    end
end

--- Open a new commented line and enter insert mode on it.
---@param offset integer  0 = below the cursor line, -1 = above
---@return nil
local function open_line(offset)
    local l, r, pad = markers()
    if not l then
        return
    end
    local row = api.nvim_win_get_cursor(0)[1]
    local cur_line = api.nvim_buf_get_lines(0, row - 1, row, false)[1] or ""
    local indent = cur_line:match("^[ \t]*") or ""
    local left = indent .. l .. pad
    local at = row + offset
    api.nvim_buf_set_lines(0, at, at, false, { left .. (r ~= "" and pad .. r or "") })
    enter_insert(at + 1, #left, r)
end

--- gco: commented line below the cursor, insert mode.
---@return nil
function M.insert_below()
    open_line(0)
end

--- gcO: commented line above the cursor, insert mode.
---@return nil
function M.insert_above()
    open_line(-1)
end

--- gcA: append a comment at the end of the current line, insert mode.
---@return nil
function M.insert_eol()
    local l, r, pad = markers()
    if not l then
        return
    end
    local row = api.nvim_win_get_cursor(0)[1]
    local line = api.nvim_buf_get_lines(0, row - 1, row, false)[1] or ""
    -- One separating space, unless the line is empty or already ends in whitespace.
    local sep = (line == "" or line:match("%s$")) and "" or " "
    -- APPEND at EOL with set_text (not set_lines rewriting the whole line) so every extmark/mark anchored on
    -- the line — diagnostics, gitsigns word-diff, user marks — survives the `gcA`.
    local prefix = sep .. l .. pad
    api.nvim_buf_set_text(0, row - 1, #line, row - 1, #line, { prefix .. (r ~= "" and pad .. r or "") })
    enter_insert(row, #line + #prefix, r)
end

return M
