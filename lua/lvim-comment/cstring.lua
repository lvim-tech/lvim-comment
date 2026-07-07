-- lvim-comment.cstring: the per-position commentstring resolver.
-- Resolution order (the plugin's whole reason to exist beside the native gc):
--   1. config.languages — the user's override, keyed by the treesitter language at the
--      position (wins inside embedded code) or by the buffer's filetype;
--   2. the built-in per-LANGUAGE table below, keyed on the treesitter language at the
--      position — this is what makes lua-in-markdown / css-in-html / jsx get their own
--      markers. JSX refinement: inside jsx MARKUP (element/fragment/attribute — but NOT
--      inside a `{ … }` jsx_expression, where plain JS comments are valid again) the
--      language is rewritten to the synthetic "jsx" row (`{/* %s */}`);
--   3. the buffer's 'commentstring' (line form only — Vim has no block option).
-- Treesitter is used through the core API only (vim.treesitter.get_parser →
-- language_for_range on the injection tree); lvim-ts merely guarantees parsers are
-- installed. Without a parser the resolver silently falls to the filetype row.
--
---@module "lvim-comment.cstring"

local api = vim.api
local config = require("lvim-comment.config")

local M = {}

---@class LvimCommentPair
---@field line string|nil   linewise commentstring, e.g. "-- %s"
---@field block string|nil  blockwise commentstring, e.g. "--[[ %s ]]"

-- Built-in { line, block } pairs, keyed by TREESITTER language name (filetypes reach
-- the table through FT_ALIAS or by sharing the name). A missing `block` means the
-- language has no practical block form — blockwise operators degrade to the linewise
-- toggle there. This data table is the plugin's real value: it is what an embedded
-- position resolves against.
---@type table<string, LvimCommentPair>
M.builtin = {
    astro = { line = "<!-- %s -->", block = "<!-- %s -->" },
    bash = { line = "# %s" },
    bibtex = { line = "% %s" },
    c = { line = "// %s", block = "/* %s */" },
    c_sharp = { line = "// %s", block = "/* %s */" },
    clojure = { line = ";; %s" },
    cmake = { line = "# %s", block = "#[[ %s ]]" },
    commonlisp = { line = ";; %s", block = "#| %s |#" },
    cpp = { line = "// %s", block = "/* %s */" },
    css = { line = "/* %s */", block = "/* %s */" },
    dart = { line = "// %s", block = "/* %s */" },
    dockerfile = { line = "# %s" },
    elixir = { line = "# %s" },
    erlang = { line = "% %s" },
    fish = { line = "# %s" },
    git_config = { line = "# %s" },
    gitcommit = { line = "# %s" },
    go = { line = "// %s", block = "/* %s */" },
    gomod = { line = "// %s" },
    graphql = { line = "# %s" },
    haskell = { line = "-- %s", block = "{- %s -}" },
    hcl = { line = "# %s", block = "/* %s */" },
    heex = { line = "<%!-- %s --%>", block = "<%!-- %s --%>" },
    html = { line = "<!-- %s -->", block = "<!-- %s -->" },
    ini = { line = "; %s" },
    java = { line = "// %s", block = "/* %s */" },
    javascript = { line = "// %s", block = "/* %s */" },
    -- Not a real parser name: the jsx-markup refinement rewrites the language to this
    -- key where plain JS comments would be a syntax error.
    jsx = { line = "{/* %s */}", block = "{/* %s */}" },
    json5 = { line = "// %s", block = "/* %s */" },
    jsonc = { line = "// %s", block = "/* %s */" },
    julia = { line = "# %s", block = "#= %s =#" },
    kotlin = { line = "// %s", block = "/* %s */" },
    latex = { line = "% %s" },
    less = { line = "// %s", block = "/* %s */" },
    lua = { line = "-- %s", block = "--[[ %s ]]" },
    make = { line = "# %s" },
    markdown = { line = "<!-- %s -->", block = "<!-- %s -->" },
    markdown_inline = { line = "<!-- %s -->", block = "<!-- %s -->" },
    matlab = { line = "% %s" },
    nix = { line = "# %s", block = "/* %s */" },
    ocaml = { line = "(* %s *)", block = "(* %s *)" },
    ocaml_interface = { line = "(* %s *)", block = "(* %s *)" },
    perl = { line = "# %s" },
    php = { line = "// %s", block = "/* %s */" },
    proto = { line = "// %s", block = "/* %s */" },
    python = { line = "# %s" },
    query = { line = "; %s" },
    r = { line = "# %s" },
    ruby = { line = "# %s" },
    rust = { line = "// %s", block = "/* %s */" },
    scala = { line = "// %s", block = "/* %s */" },
    scheme = { line = ";; %s" },
    scss = { line = "// %s", block = "/* %s */" },
    sql = { line = "-- %s", block = "/* %s */" },
    svelte = { line = "<!-- %s -->", block = "<!-- %s -->" },
    swift = { line = "// %s", block = "/* %s */" },
    terraform = { line = "# %s", block = "/* %s */" },
    toml = { line = "# %s" },
    tsx = { line = "// %s", block = "/* %s */" },
    twig = { line = "{# %s #}", block = "{# %s #}" },
    typescript = { line = "// %s", block = "/* %s */" },
    typst = { line = "// %s", block = "/* %s */" },
    vim = { line = '" %s' },
    vue = { line = "<!-- %s -->", block = "<!-- %s -->" },
    xml = { line = "<!-- %s -->", block = "<!-- %s -->" },
    yaml = { line = "# %s" },
    zig = { line = "// %s" },
}

-- Filetypes whose name differs from their treesitter language — the fallback lookup
-- when no parser is attached (with a parser, language_for_range already yields the
-- canonical language name).
---@type table<string, string>
local FT_ALIAS = {
    cs = "c_sharp",
    dosini = "ini",
    javascriptreact = "javascript",
    plaintex = "latex",
    sh = "bash",
    tex = "latex",
    typescriptreact = "tsx",
    zsh = "bash",
}

-- Grammars that contain jsx nodes (jsx has no parser of its own — it lives inside
-- these languages' trees).
---@type table<string, boolean>
local JSX_LANGS = { javascript = true, tsx = true }

-- Node types that put a position inside jsx MARKUP (where only `{/* */}` comments).
---@type table<string, boolean>
local JSX_MARKUP = {
    jsx_element = true,
    jsx_fragment = true,
    jsx_self_closing_element = true,
    jsx_opening_element = true,
    jsx_closing_element = true,
    jsx_attribute = true,
    jsx_text = true,
}

--- Whether the position sits in jsx markup rather than in embedded JS: walking up from
--- the node at the position, the FIRST decisive ancestor wins — a jsx_expression means
--- plain JS comments are valid again (a `{ … }` hole), a markup node means `{/* */}`.
---@param bufnr integer
---@param pos integer[]  { row0, col0 }
---@return boolean
local function in_jsx_markup(bufnr, pos)
    local ok, node = pcall(vim.treesitter.get_node, { bufnr = bufnr, pos = { pos[1], pos[2] } })
    if not ok or not node then
        return false
    end
    while node do
        local t = node:type()
        if t == "jsx_expression" then
            return false
        end
        if JSX_MARKUP[t] then
            return true
        end
        node = node:parent()
    end
    return false
end

--- The treesitter language at a position, via the buffer's parser tree (injections
--- included). nil when no parser is available — the caller falls back to the filetype.
---@param bufnr integer
---@param pos integer[]  { row0, col0 }
---@return string|nil
local function language_at(bufnr, pos)
    local ok, parser = pcall(vim.treesitter.get_parser, bufnr)
    if not ok or not parser then
        return nil
    end
    -- language_for_range needs a parsed tree (injections included). An attached
    -- highlighter keeps it parsed; a bare buffer does not — parse() is incremental,
    -- so this is cheap when nothing changed.
    pcall(parser.parse, parser, true)
    local ok_range, tree = pcall(parser.language_for_range, parser, { pos[1], pos[2], pos[1], pos[2] })
    if ok_range and tree then
        return tree:lang()
    end
    return nil
end

--- Resolve the effective commentstring pair at a position (see the module header for
--- the order). Returns nil only when nothing applies — no table row and an empty or
--- %s-less 'commentstring'.
---@param bufnr? integer  buffer (nil/0: current)
---@param pos? integer[]  { row0, col0 }; default: the cursor (or {0,0} for another buffer)
---@return LvimCommentPair|nil
function M.resolve(bufnr, pos)
    if bufnr == nil or bufnr == 0 then
        bufnr = api.nvim_get_current_buf()
    end
    if not pos then
        if bufnr == api.nvim_get_current_buf() then
            local cur = api.nvim_win_get_cursor(0)
            pos = { cur[1] - 1, cur[2] }
        else
            pos = { 0, 0 }
        end
    end

    local ft = vim.bo[bufnr].filetype
    local lang = language_at(bufnr, pos)
    if lang and JSX_LANGS[lang] and in_jsx_markup(bufnr, pos) then
        lang = "jsx"
    end

    local user = config.languages or {}
    -- A detected language binds the lookup to IT (user override first) — the filetype
    -- row must not shadow an embedded language's markers.
    local pair = lang and (user[lang] or M.builtin[lang]) or nil
    if not pair then
        pair = user[ft] or M.builtin[FT_ALIAS[ft] or ft]
    end
    if pair then
        return { line = pair.line, block = pair.block }
    end

    local cs = vim.bo[bufnr].commentstring
    if type(cs) == "string" and cs:find("%%s") then
        return { line = cs }
    end
    return nil
end

return M
