-- lvim-comment.engine: the pure text transforms (no buffer access, no vim state).
-- Takes an array of lines (or one line + a byte range) plus a commentstring and returns
-- the toggled result, so every transform is unit-testable headlessly. Toggle semantics:
-- all non-blank lines commented → uncomment; mixed/uncommented → comment. Linewise
-- commenting skips blank lines and aligns every marker at the LONGEST COMMON whitespace
-- prefix of the range (a byte-wise common prefix — unlike a "shortest indent" heuristic
-- it can never splice a tab-indented marker into a space-indented line). Uncommenting
-- tolerates both padded and unpadded markers, so `padding` can be flipped at any time
-- and old comments still round-trip.
--
---@module "lvim-comment.engine"

local M = {}

--- Escape Lua pattern magic characters, so a marker like `*/` or `--[[` is matched
--- literally.
---@param s string
---@return string
local function esc(s)
    return (s:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0"))
end

--- Split a commentstring into its trimmed left/right markers ("<!-- %s -->" → "<!--",
--- "-->"). The engine re-applies spacing itself (per `padding`), so table entries and
--- 'commentstring' values behave identically whether they carry spaces around %s or not.
---@param cs string
---@return string left, string right
function M.parts(cs)
    local l, r = cs:match("^(.-)%%s(.*)$")
    if not l then
        return vim.trim(cs), ""
    end
    return vim.trim(l), vim.trim(r)
end

--- Whether a line is commented with the given (escaped) markers: left marker right
--- after the indent and — when the commentstring has a closing side — the right marker
--- at the end (trailing whitespace allowed).
---@param line string
---@param el string  escaped left marker
---@param er string  escaped right marker ("" when the commentstring has none)
---@return boolean
local function commented(line, el, er)
    local rest = line:match("^%s*" .. el .. "(.*)$")
    if not rest then
        return false
    end
    if er ~= "" then
        return rest:match(er .. "%s*$") ~= nil
    end
    return true
end

--- Strip the markers from one commented line (one pad space on each side is absorbed).
--- A marker-only line ("--", "<!-- -->") uncomments to an empty line.
---@param line string
---@param el string  escaped left marker
---@param er string  escaped right marker ("" when none)
---@return string
local function uncomment(line, el, er)
    local indent, rest = line:match("^(%s*)" .. el .. "%s?(.*)$")
    if not indent then
        return line
    end
    if er ~= "" then
        rest = rest:match("^(.-)%s?" .. er .. "%s*$") or rest
    end
    if rest == "" then
        return ""
    end
    return indent .. rest
end

--- The longest COMMON leading-whitespace prefix of the non-blank lines — the byte-safe
--- alignment column for the markers (a mere "shortest indent" would corrupt lines when
--- tabs and spaces are mixed, because it cuts other lines at a byte count that is not a
--- prefix of THEIR indent).
---@param lines string[]
---@return string
local function common_indent(lines)
    local best
    for _, line in ipairs(lines) do
        if line:match("%S") then
            local ws = line:match("^[ \t]*")
            if best == nil then
                best = ws
            else
                local n = math.min(#best, #ws)
                local i = 0
                while i < n and best:byte(i + 1) == ws:byte(i + 1) do
                    i = i + 1
                end
                best = best:sub(1, i)
            end
        end
    end
    return best or ""
end

--- Toggle LINE comments on a range of lines. Blank lines are skipped when commenting
--- and ignored by the all-commented check; a blank-only range gets bare markers (so
--- `gcc` on an empty line still produces a comment to type after).
---@param lines string[]
---@param cs string  the linewise commentstring ("-- %s")
---@param padding boolean  one space between marker and text
---@return string[] out  the toggled lines (same count)
---@return boolean commented_now  true when the range was commented, false when uncommented
function M.toggle_line(lines, cs, padding)
    local l, r = M.parts(cs)
    local el, er = esc(l), esc(r)
    local pad = padding and " " or ""
    local out = {}

    local any, all = false, true
    for _, line in ipairs(lines) do
        if line:match("%S") then
            any = true
            if not commented(line, el, er) then
                all = false
            end
        end
    end

    if any and all then
        for i, line in ipairs(lines) do
            out[i] = line:match("%S") and uncomment(line, el, er) or line
        end
        return out, false
    end

    if not any then
        -- Blank-only range: a bare marker per line (no trailing pad — no trailing
        -- whitespace left behind), with the closing side when the language has one.
        for i = 1, #lines do
            out[i] = l .. (r ~= "" and pad .. r or "")
        end
        return out, true
    end

    local indent = common_indent(lines)
    for i, line in ipairs(lines) do
        if line:match("%S") then
            out[i] = indent .. l .. pad .. line:sub(#indent + 1) .. (r ~= "" and pad .. r or "")
        else
            out[i] = line
        end
    end
    return out, true
end

--- Toggle a BLOCK comment around a range of lines: the left marker goes after the
--- first non-blank line's own indent, the right marker at the end of the last
--- non-blank line (both on the same line for a single-line range). Detection requires
--- BOTH markers, so a range that merely starts with a line comment is (re)commented,
--- not mangled.
---@param lines string[]
---@param cs string  the blockwise commentstring ("/* %s */" — must have both sides)
---@param padding boolean
---@return string[] out
---@return boolean commented_now
function M.toggle_block(lines, cs, padding)
    local l, r = M.parts(cs)
    local el, er = esc(l), esc(r)
    local pad = padding and " " or ""

    local out = {}
    local first, last
    for i, line in ipairs(lines) do
        out[i] = line
        if line:match("%S") then
            first = first or i
            last = i
        end
    end
    first, last = first or 1, last or #lines

    local head, tail = out[first], out[last]
    local hindent, hrest = head:match("^(%s*)" .. el .. "%s?(.*)$")
    if hindent and tail:match(er .. "%s*$") then
        if first == last then
            local mid = hrest:match("^(.-)%s?" .. er .. "%s*$") or hrest
            out[first] = mid == "" and "" or hindent .. mid
        else
            out[first] = hrest == "" and "" or hindent .. hrest
            local stripped = tail:match("^(.-)%s?" .. er .. "%s*$") or tail
            out[last] = stripped:match("%S") and stripped or ""
        end
        return out, false
    end

    local indent = head:match("^[ \t]*")
    out[first] = indent .. l .. pad .. head:sub(#indent + 1)
    out[last] = out[last] .. pad .. r
    return out, true
end

--- Toggle an INLINE block comment around a same-line byte range (charwise `gb`): the
--- region is wrapped as `l pad region pad r`, or unwrapped when it already IS exactly
--- such a comment.
---@param line string
---@param scol integer  1-based inclusive start byte column
---@param ecol integer  1-based inclusive end byte column (the last char's LAST byte)
---@param cs string  the blockwise commentstring (both sides present)
---@param padding boolean
---@return string out
---@return boolean commented_now
function M.toggle_inline(line, scol, ecol, cs, padding)
    local l, r = M.parts(cs)
    local el, er = esc(l), esc(r)
    local pad = padding and " " or ""

    local before = line:sub(1, scol - 1)
    local inner = line:sub(scol, ecol)
    local after = line:sub(ecol + 1)

    local mid = inner:match("^" .. el .. "%s?(.*)$")
    if mid then
        local stripped = mid:match("^(.-)%s?" .. er .. "$")
        if stripped then
            return before .. stripped .. after, false
        end
    end
    return before .. l .. pad .. inner .. pad .. r .. after, true
end

return M
