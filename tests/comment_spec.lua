-- The transforms, the data table, and what a position resolves to.
--
-- engine.lua opens by saying it is "pure text transforms (no buffer access, no vim state) …
-- so every transform is unit-testable headlessly". It was, and nothing tested it. The property
-- that matters most is reversibility: a toggle followed by the same toggle gives back exactly
-- the lines that went in, for every shape of input -- which is the only guarantee a user
-- actually relies on when they press the key twice.

local engine = require("lvim-comment.engine")
local cstring = require("lvim-comment.cstring")
local config = require("lvim-comment.config")

describe("lvim-comment: splitting a commentstring")

it("the markers come out trimmed, with or without spaces around %s", function()
    local function parts(cs)
        local l, r = engine.parts(cs)
        return { l, r }
    end
    eq({ "--", "" }, parts("-- %s"))
    eq({ "//", "" }, parts("//%s"), "a commentstring without spacing gives the same markers")
    eq({ "/*", "*/" }, parts("/* %s */"))
    eq({ "<!--", "-->" }, parts("<!-- %s -->"))
    eq({ "--[[", "]]" }, parts("--[[ %s ]]"))
    eq({ "<%!--", "--%>" }, parts("<%!-- %s --%>"), "a marker may contain % itself")
    eq({ "--", "" }, parts("--"), "a commentstring with no %s at all is still a left marker")
end)

describe("lvim-comment: a toggle is reversible")

-- Every shape worth worrying about: indents that agree, indents that do not, tabs against
-- spaces, blank lines inside and at the edges, both padding settings, and a language whose LINE
-- form is really a block form (css).
local SHAPES = {
    { lines = { "local x = 1" }, cs = "-- %s" },
    { lines = { "  a", "    b" }, cs = "-- %s" },
    { lines = { "\ta", "\t\tb" }, cs = "-- %s" },
    { lines = { "  a", "\tb" }, cs = "-- %s" },
    { lines = { "a", "", "b" }, cs = "-- %s" },
    { lines = { "" }, cs = "-- %s" },
    { lines = { "", "" }, cs = "/* %s */" },
    { lines = { "a" }, cs = "/* %s */" },
    { lines = { "a", "b" }, cs = "<!-- %s -->" },
    { lines = { "  x" }, cs = "--[[ %s ]]" },
    { lines = { "p { color: red }" }, cs = "/* %s */" },
    { lines = { "let x" }, cs = '" %s' },
}

for _, padding in ipairs({ true, false }) do
    it("linewise, padding " .. tostring(padding), function()
        for _, shape in ipairs(SHAPES) do
            local once = engine.toggle_line(shape.lines, shape.cs, padding)
            local twice = engine.toggle_line(once, shape.cs, padding)
            eq(
                shape.lines,
                twice,
                ("%s with %s did not come back: %s"):format(vim.inspect(shape.lines), shape.cs, vim.inspect(once))
            )
        end
    end)
end

it("blockwise, both padding settings", function()
    local block_shapes = {
        { { "a" }, "/* %s */" },
        { { "a", "b" }, "/* %s */" },
        { { "  a", "  b" }, "/* %s */" },
        { { "", "a", "" }, "/* %s */" },
        { { "x" }, "--[[ %s ]]" },
        { { "a", "b", "c" }, "<!-- %s -->" },
    }
    for _, padding in ipairs({ true, false }) do
        for _, shape in ipairs(block_shapes) do
            local once = engine.toggle_block(shape[1], shape[2], padding)
            local twice = engine.toggle_block(once, shape[2], padding)
            eq(shape[1], twice, vim.inspect(shape[1]) .. " via " .. vim.inspect(once))
        end
    end
end)

it("an inline region comes back, on a multibyte line too", function()
    local out = engine.toggle_inline("abcdef", 2, 4, "/* %s */", true)
    eq("a/* bcd */ef", out)
    eq("abcdef", (engine.toggle_inline(out, 2, 10, "/* %s */", true)))

    -- Columns are BYTES: "аб" is the first four bytes of "абвгд".
    local cyr = engine.toggle_inline("абвгд", 1, 4, "/* %s */", true)
    eq("/* аб */вгд", cyr)
    eq("абвгд", (engine.toggle_inline(cyr, 1, 10, "/* %s */", true)))
end)

describe("lvim-comment: where the marker goes")

it("markers align at the longest COMMON whitespace prefix", function()
    local out = engine.toggle_line({ "  a", "    b" }, "-- %s", true)
    eq({ "  -- a", "  --   b" }, out, "the deeper line keeps its extra indent AFTER the marker")
end)

it("a tab-indented and a space-indented line share no prefix, so nothing is spliced", function()
    -- A "shortest indent" heuristic would cut "\tb" at one byte and splice the marker into the
    -- middle of an indent that is not a prefix of it. A common PREFIX cannot do that.
    local out = engine.toggle_line({ "  a", "\tb" }, "-- %s", true)
    eq({ "--   a", "-- \tb" }, out)
    eq({ "  a", "\tb" }, (engine.toggle_line(out, "-- %s", true)))
end)

it("a blank-only range gets bare markers and no trailing whitespace", function()
    eq({ "--" }, (engine.toggle_line({ "" }, "-- %s", true)))
    eq({ "/* */" }, (engine.toggle_line({ "" }, "/* %s */", true)), "with a closing side, the pad stays inside")
end)

it("blank lines inside a range are left exactly as they are", function()
    eq({ "-- a", "", "-- b" }, (engine.toggle_line({ "a", "", "b" }, "-- %s", true)))
    eq({ "-- a", "   ", "-- b" }, (engine.toggle_line({ "a", "   ", "b" }, "-- %s", true)))
end)

describe("lvim-comment: what counts as already commented")

it("uncommenting is the exact inverse of what the current padding writes", function()
    -- With padding ON, both old forms come out clean: the pad is absorbed when it is there and
    -- there is nothing to absorb when it is not.
    eq({ "a" }, (engine.toggle_line({ "-- a" }, "-- %s", true)))
    eq({ "a" }, (engine.toggle_line({ "--a" }, "-- %s", true)))

    -- With padding OFF nothing may be absorbed, because the engine never wrote a pad and the
    -- text after a marker can legitimately begin with whitespace. So a comment written earlier
    -- WITH a pad keeps that one space -- visible, and the price of the toggle being reversible
    -- for a line indented deeper than its range's common indent.
    eq({ " a" }, (engine.toggle_line({ "-- a" }, "-- %s", false)))
    eq({ "a" }, (engine.toggle_line({ "--a" }, "-- %s", false)))
end)

it("a mixed range is commented, not half-uncommented", function()
    local out, commented_now = engine.toggle_line({ "-- a", "b" }, "-- %s", true)
    eq({ "-- -- a", "-- b" }, out)
    eq(true, commented_now)
    eq({ "-- a", "b" }, (engine.toggle_line(out, "-- %s", true)), "and it is still reversible")
end)

it("a block toggle needs BOTH markers before it will uncomment", function()
    -- A range that merely starts with a line comment is commented, never mangled.
    local out, commented_now = engine.toggle_block({ "-- a" }, "/* %s */", true)
    eq({ "/* -- a */" }, out)
    eq(true, commented_now)
end)

it("the reported direction matches what happened", function()
    local _, first = engine.toggle_line({ "a" }, "-- %s", true)
    eq(true, first)
    local _, second = engine.toggle_line({ "-- a" }, "-- %s", true)
    eq(false, second)
end)

it("a marker-only line uncomments to an empty line, not to the marker", function()
    eq({ "" }, (engine.toggle_line({ "--" }, "-- %s", true)))
    eq({ "" }, (engine.toggle_line({ "/* */" }, "/* %s */", true)))
end)

describe("lvim-comment: the built-in language table")

it("every entry is a usable commentstring", function()
    local count = 0
    for lang, pair in pairs(cstring.builtin) do
        count = count + 1
        for _, kind in ipairs({ "line", "block" }) do
            local cs = pair[kind]
            if cs then
                local _, n = cs:gsub("%%s", "")
                eq(1, n, ("%s.%s has %d placeholders: %s"):format(lang, kind, n, cs))
                local l, r = engine.parts(cs)
                truthy(l ~= "", ("%s.%s has no left marker"):format(lang, kind))
                if kind == "block" then
                    truthy(r ~= "", ("%s.block has no closing marker: %s"):format(lang, cs))
                end
            end
        end
        truthy(pair.line or pair.block, lang .. " declares neither form")
    end
    truthy(count > 50, "the table is the plugin's real value; it should be big (" .. count .. ")")
end)

it("every entry round-trips through the engine", function()
    for lang, pair in pairs(cstring.builtin) do
        for _, kind in ipairs({ "line", "block" }) do
            local cs = pair[kind]
            if cs then
                local lines = { "  keep me", "and me" }
                local once = engine.toggle_line(lines, cs, true)
                eq(lines, (engine.toggle_line(once, cs, true)), lang .. "." .. kind .. " via " .. vim.inspect(once))
            end
        end
    end
end)

describe("lvim-comment: resolving a position")

--- A buffer of `ft` holding `lines`, current, with the cursor at (row1, col0).
---@param ft string
---@param lines string[]
---@return integer buf
local function buffer_of(ft, lines)
    vim.cmd("enew!")
    local buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].filetype = ft
    return buf
end

it("a filetype resolves to its own markers", function()
    buffer_of("lua", { "local x = 1" })
    local pair = cstring.resolve()
    truthy(pair)
    eq("-- %s", pair.line)
    eq("--[[ %s ]]", pair.block)
end)

it("a filetype whose name differs from its grammar resolves through the alias", function()
    buffer_of("zsh", { "echo hi" })
    local pair = cstring.resolve()
    truthy(pair)
    eq("# %s", pair.line, "zsh is parsed as bash")
end)

it("a user override beats the built-in row", function()
    buffer_of("lua", { "local x = 1" })
    local was = config.languages
    config.languages = { lua = { line = ";; %s" } }
    local pair = cstring.resolve()
    config.languages = was
    truthy(pair)
    eq(";; %s", pair.line)
end)

it("an unknown filetype falls back to the buffer's own commentstring", function()
    local buf = buffer_of("lvim-comment-spec-ft", { "x" })
    vim.bo[buf].commentstring = ";; %s"
    local pair = cstring.resolve()
    truthy(pair)
    eq(";; %s", pair.line)
    eq(nil, pair.block, "Vim has no block option to fall back to")
end)

it("nothing applicable resolves to nothing, rather than to a guess", function()
    local buf = buffer_of("lvim-comment-spec-ft", { "x" })
    vim.bo[buf].commentstring = ""
    eq(nil, cstring.resolve())
    -- The resolver also rejects a non-empty 'commentstring' without a %s, but that state cannot
    -- be reached from here: Vim refuses the assignment itself with E537.
    local ok = pcall(function()
        vim.bo[buf].commentstring = "no placeholder here"
    end)
    eq(false, ok, "Vim itself will not hold a commentstring without %s")
end)

it("the language at the POSITION wins inside embedded code", function()
    local ok = pcall(vim.treesitter.get_string_parser, "", "markdown")
    if not ok then
        skip("embedded language resolution", "the markdown parser is not installed on this machine")
        return
    end
    local buf = buffer_of("markdown", {
        "text",
        "```lua",
        "local x = 1",
        "```",
    })
    -- Force the injection tree to exist before asking.
    pcall(function()
        vim.treesitter.get_parser(buf):parse(true)
    end)

    local outside = cstring.resolve(buf, { 0, 0 })
    truthy(outside)
    eq("<!-- %s -->", outside.line, "plain markdown")

    local inside = cstring.resolve(buf, { 2, 0 })
    truthy(inside)
    eq("-- %s", inside.line, "inside the lua fence the position decides, not the filetype")
end)
