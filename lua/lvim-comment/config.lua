-- lvim-comment: the live configuration table.
-- Holds the defaults; setup() merges user overrides into it in place, so every
-- require("lvim-comment.config") reader sees the effective values. `padding`, `sticky`
-- and `languages` are read at toggle time (flippable at runtime without a restart);
-- `mappings` is read once by setup() when the keys are defined.
--
---@module "lvim-comment.config"

---@class LvimCommentMappings
---@field basic boolean  `gc`/`gb` operators, `gcc`/`gbb` current line, visual `gc`/`gb`
---@field extra boolean  `gco` / `gcO` (open commented line below/above) and `gcA` (append comment at EOL)

---@class LvimCommentConfig
---@field padding boolean  one space between the comment marker and the text
---@field sticky boolean   keep the cursor where it was when the operator was triggered
---@field mappings LvimCommentMappings  which default key sets setup() installs
---@field languages table<string, { line?: string, block?: string }>  per-language/filetype commentstring overrides

---@type LvimCommentConfig
return {
    -- One space between marker and text ("-- foo" vs "--foo"); uncommenting strips the
    -- pad space either way, so toggling round-trips regardless of this setting.
    padding = true,
    -- Restore the cursor to where it was when the operator was triggered (an operator
    -- normally leaves it at the start of the range).
    sticky = true,
    -- basic: `gc{motion}` / `gb{motion}`, `gcc` / `gbb` (count-aware), visual `gc`/`gb` —
    -- these REPLACE Neovim's built-in linewise gc set (same keys, one engine for line +
    -- block). extra: `gco` / `gcO` / `gcA` insert-mode entry points.
    mappings = {
        basic = true,
        extra = true,
    },
    -- Per-language { line, block } commentstring overrides, keyed by TREESITTER language
    -- name (wins inside embedded code too) or by FILETYPE (buffer-wide). Checked before
    -- the built-in table and before 'commentstring':
    --   languages = { lua = { line = "-- %s", block = "--[[ %s ]]" } }
    languages = {},
}
