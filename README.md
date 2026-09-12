# lvim-comment

Comment toggling for Neovim with **operators, counts and dot-repeat** — linewise and
blockwise commenting through **one engine and one commentstring resolver**, built on the
lvim-tech ecosystem (uses `lvim-utils` for its shared merge).

It replaces Neovim's built-in linewise `gc` mappings (config-gated) so line and block
comments behave identically: `gc{motion}` / `gcc` / visual `gc` toggle line comments,
`gb{motion}` / `gbb` / visual `gb` toggle a block comment — and a **charwise same-line
`gb` produces a true inline block comment** (`local --[[ x ]] = 1`). The operator is a
plain `'operatorfunc'` behind `g@`, so **counts** (`3gcc`) and **dot-repeat** come from
Vim itself — no key replay, no count bookkeeping.

The commentstring is resolved **per position**, not per buffer:

1. `languages` — your override, keyed by **treesitter language** (wins inside embedded
   code too) or by **filetype** (buffer-wide);
2. the built-in per-language table, keyed on the treesitter **language at the range
   start** (via the buffer's parser tree, injections included) — so lua-in-markdown,
   css-in-html and jsx each get their own markers. Inside **jsx markup**
   (element/fragment/attribute — but not inside a `{ … }` expression, where plain JS
   comments are valid again) the pair becomes `{/* %s */}`;
3. the buffer's `'commentstring'` (line form) as the last resort.

Treesitter is used through the core API only (`vim.treesitter.get_parser` →
`language_for_range`); [lvim-ts](https://github.com/lvim-tech/lvim-ts) merely guarantees
parsers are installed (optional — without a parser the resolver falls to the filetype
row).

Toggle semantics: **all** non-blank lines commented → uncomment; mixed or uncommented →
comment. Linewise commenting skips blank lines and aligns every marker at the longest
**common whitespace prefix** of the range (byte-safe with mixed tabs/spaces).
Uncommenting tolerates both padded and unpadded markers, so `padding` can be flipped at
any time and old comments still round-trip.

The built-in operator-pending `gc` (the comment-lines **textobject**) is deliberately
left alone — it composes with any operator (`dgc`, `ygc`) and does not overlap with the
mappings here.

[![License: BSD-3-Clause](https://img.shields.io/badge/License-BSD--3--Clause-blue.svg)](https://github.com/lvim-tech/lvim-comment/blob/main/LICENSE)

## Requirements

- Neovim **>= 0.12**
- [lvim-utils](https://github.com/lvim-tech/lvim-utils) (optional — shared `merge`)
- [lvim-ts](https://github.com/lvim-tech/lvim-ts) (optional — installs treesitter
  parsers on demand; core `vim.treesitter` does the actual resolution)

## Installation

### lvim-installer (recommended)

```lua
require("lvim-installer").install("lvim-comment")
```

### Native (vim.pack)

```lua
vim.pack.add({
    "https://github.com/lvim-tech/lvim-utils",
    "https://github.com/lvim-tech/lvim-comment",
})
```

## Setup

The full default configuration — every option at its default value:

```lua
require("lvim-comment").setup({
    -- One space between marker and text ("-- foo" vs "--foo"); uncommenting strips
    -- the pad space either way, so toggling round-trips regardless of this setting.
    padding = true,
    -- Restore the cursor to where it was when the operator was triggered (an operator
    -- normally leaves it at the start of the range).
    sticky = true,
    -- basic: `gc{motion}` / `gb{motion}`, `gcc` / `gbb` (count-aware), visual `gc`/`gb`
    -- — these REPLACE Neovim's built-in linewise gc set. extra: `gco` / `gcO` / `gcA`.
    mappings = {
        basic = true,
        extra = true,
    },
    -- Per-language { line, block } commentstring overrides, keyed by TREESITTER
    -- language name (wins inside embedded code too) or by FILETYPE (buffer-wide).
    -- Checked before the built-in table and before 'commentstring':
    --   languages = { lua = { line = "-- %s", block = "--[[ %s ]]" } }
    languages = {},
})
```

## Mappings

With `mappings.basic = true` (all support counts and dot-repeat):

| Keys         | Mode | Action                                                        |
| ------------ | ---- | ------------------------------------------------------------- |
| `gc{motion}` | n    | Toggle line comments over the motion (`gcip`, `gc3j`, `gcG`)  |
| `gcc`        | n    | Toggle line comment on the current line (`3gcc` = 3 lines)    |
| `gb{motion}` | n    | Toggle a block comment over the motion                        |
| `gbb`        | n    | Toggle a block comment on the current line                    |
| `gc`         | x    | Toggle line comments on the selection                         |
| `gb`         | x    | Toggle a block comment on the selection (charwise → inline)   |

With `mappings.extra = true`:

| Keys  | Mode | Action                                                  |
| ----- | ---- | ------------------------------------------------------- |
| `gco` | n    | Open a commented line **below** and enter insert mode   |
| `gcO` | n    | Open a commented line **above** and enter insert mode   |
| `gcA` | n    | Append a comment at the **end of line**, insert mode    |

All keys are also available as `<Plug>` mappings for custom keys (set `basic` / `extra`
to `false` and map your own):

```lua
vim.keymap.set("n", "<leader>c", "<Plug>(lvim-comment-toggle-linewise)")
vim.keymap.set("n", "<leader>cc", "<Plug>(lvim-comment-toggle-linewise-current)")
vim.keymap.set("n", "<leader>b", "<Plug>(lvim-comment-toggle-blockwise)")
vim.keymap.set("n", "<leader>bb", "<Plug>(lvim-comment-toggle-blockwise-current)")
vim.keymap.set("x", "<leader>c", "<Plug>(lvim-comment-toggle-linewise-visual)")
vim.keymap.set("x", "<leader>b", "<Plug>(lvim-comment-toggle-blockwise-visual)")
vim.keymap.set("n", "<leader>co", "<Plug>(lvim-comment-insert-below)")
vim.keymap.set("n", "<leader>cO", "<Plug>(lvim-comment-insert-above)")
vim.keymap.set("n", "<leader>cA", "<Plug>(lvim-comment-insert-eol)")
```

Languages without a block form (python, yaml, …) degrade blockwise operators to the
linewise toggle — every line still ends up commented.

## Command

```
:[range]LvimComment [line|block]
```

Toggles comments over the range (default: the current line, `line` form). `:'<,'>LvimComment block`
wraps the selection in a block comment.

## API

```lua
-- Toggle LINE comments on an inclusive 1-based line range (bufnr optional).
require("lvim-comment").toggle_lines(s, e, bufnr)

-- Toggle a BLOCK comment around an inclusive 1-based line range
-- (falls back to toggle_lines when the language has no block form).
require("lvim-comment").toggle_block(s, e, bufnr)

-- Resolve the effective commentstring pair at a position (both args optional:
-- pos is { row0, col0 }, defaults to the cursor) → { line, block } or nil.
require("lvim-comment").resolve(bufnr, pos)
```

`resolve()` is public on purpose — any plugin that needs a position-aware
commentstring (tables, snippets, generators) can query it instead of reading
`'commentstring'`.

## Built-in language table

Around 60 languages ship with `{ line, block }` pairs keyed by treesitter language name
(`lua`, `python`, `javascript`, `tsx`, `css`, `html`, `markdown`, `rust`, `go`, `haskell`,
`ocaml`, `julia`, …), plus filetype aliases (`sh` → `bash`, `typescriptreact` → `tsx`,
`cs` → `c_sharp`, …). A synthetic `jsx` row (`{/* %s */}`) is selected automatically
inside jsx markup. Anything can be overridden per language or per filetype via
`languages`.

## Health

```
:checkhealth lvim-comment
```

Reports the Neovim/lvim-utils requirements, whether a treesitter parser is attached to
the current buffer (embedded-language resolution), whether the default keys are still
bound to lvim-comment (or what shadows them), the pair the resolver would use at the
cursor, and validates the config shape.
