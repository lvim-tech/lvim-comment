-- lvim-comment.engine: the pure text transforms (no buffer access, no vim state).
-- Takes an array of lines (or one line + a byte range) plus a commentstring and returns
-- the toggled result, so every transform is unit-testable headlessly. Toggle semantics:
-- all non-blank lines commented → uncomment; mixed/uncommented → comment. Linewise
-- commenting skips blank lines and aligns every marker at the LONGEST COMMON whitespace
-- prefix of the range (a byte-wise common prefix — unlike a "shortest indent" heuristic
-- it can never splice a tab-indented marker into a space-indented line).
--
-- Uncommenting is the exact INVERSE of what the current `padding` writes: with padding on one
-- space is absorbed on each side, with padding off nothing is. That is what makes a toggle
-- reversible for every input, including a line indented deeper than the range's common indent —
-- whose extra indent sits after the marker and was being eaten. The cost is in the other
-- direction and is deliberate: with padding OFF, a comment written earlier WITH a pad uncomments
-- to text with one leading space. With padding on (the default) both old forms round-trip.
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

--- Drop the PAD space from the FRONT of `s`.
---
--- The pad is one SPACE, and it exists only when `padding` is on. With padding OFF the engine
--- never writes one, so nothing may be taken away: the text after a marker can legitimately
--- begin with whitespace — a line indented deeper than the range's common indent carries the
--- difference as its own leading space or tab — and taking a character of that silently
--- re-indented the line. Measured: with padding off, `{"  a", "    b"}` came back as
--- `{"  a", "   b"}`, and `{"\ta", "\t\tb"}` lost its tab.
---
--- The cost is small and in the other direction: with padding off, a comment written earlier
--- WITH a pad uncomments to text with one leading space. That is visible and harmless, where a
--- changed indent is neither.
---@param s string
---@param padding boolean
---@return string
local function strip_pad_left(s, padding)
    if not padding then
        return s
    end
    return s:match("^ (.*)$") or s
end

--- The mirror of strip_pad_left for the space before a closing marker.
---@param s string
---@param padding boolean
---@return string
local function strip_pad_right(s, padding)
    if not padding then
        return s
    end
    return s:match("^(.-) $") or s
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

--- Strip the markers from one commented line (the pad space on each side is absorbed when it
--- really is a pad — see strip_pad_left). A marker-only line ("--", "<!-- -->") uncomments to an
--- empty line.
---@param line string
---@param el string  escaped left marker
---@param er string  escaped right marker ("" when none)
---@param padding boolean  whether a pad space is being written today
---@return string
local function uncomment(line, el, er, padding)
    local indent, rest = line:match("^(%s*)" .. el .. "(.*)$")
    if not indent then
        return line
    end
    rest = strip_pad_left(rest, padding)
    if er ~= "" then
        local inner = rest:match("^(.-)" .. er .. "%s*$")
        if inner then
            rest = strip_pad_right(inner, padding)
        end
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
            out[i] = line:match("%S") and uncomment(line, el, er, padding) or line
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
    local hindent, hraw = head:match("^(%s*)" .. el .. "(.*)$")
    local hrest = hraw and strip_pad_left(hraw, padding) or nil
    if hindent and tail:match(er .. "%s*$") then
        --- The text before a closing marker, with its pad space dropped when it is one.
        ---@param s string
        ---@return string|nil
        local function before_close(s)
            local inner = s:match("^(.-)" .. er .. "%s*$")
            return inner and strip_pad_right(inner, padding) or nil
        end
        if first == last then
            local mid = before_close(hrest) or hrest
            out[first] = mid == "" and "" or hindent .. mid
        else
            out[first] = hrest == "" and "" or hindent .. hrest
            local stripped = before_close(tail) or tail
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

    local raw = inner:match("^" .. el .. "(.*)$")
    if raw then
        local mid = strip_pad_left(raw, padding)
        local closed = mid:match("^(.-)" .. er .. "$")
        if closed then
            return before .. strip_pad_right(closed, padding) .. after, false
        end
    end
    return before .. l .. pad .. inner .. pad .. r .. after, true
end

return M
