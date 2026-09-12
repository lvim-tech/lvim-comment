-- lvim-comment: :checkhealth lvim-comment.
-- Diagnoses what makes comment toggling misbehave INVISIBLY: mappings that did not land
-- (setup() not called, or another plugin re-mapped gc/gb after us), a buffer without a
-- treesitter parser (embedded-language resolution silently degrades to the filetype
-- row / 'commentstring'), and config shapes that would only explode at toggle time.
-- Also reports the pair the resolver would use at the CURSOR, so "wrong marker" reports
-- can be checked on the spot. Read-only reporting — never mutates config or state.
--
---@module "lvim-comment.health"

local config = require("lvim-comment.config")
local cstring = require("lvim-comment.cstring")

local M = {}

--- Report whether a default key is bound to our <Plug> mapping (or what shadows it).
---@param health table  the vim.health reporter
---@param lhs string  the key sequence
---@param mode string  keymap mode short-name
---@return nil
local function check_map(health, lhs, mode)
    local map = vim.fn.maparg(lhs, mode, false, true)
    local rhs = type(map) == "table" and map.rhs or nil
    if type(rhs) == "string" and rhs:find("lvim-comment", 1, true) then
        health.ok(("%s-mode %s → %s"):format(mode, lhs, rhs))
    elseif map == nil or vim.tbl_isempty(map) then
        health.warn(("%s-mode %s is not mapped — was setup() called?"):format(mode, lhs))
    else
        health.warn(
            ("%s-mode %s is mapped by something else (%s) — it shadows lvim-comment"):format(
                mode,
                lhs,
                rhs or (map.callback and "a Lua callback" or "?")
            )
        )
    end
end

--- Validate the live config table; error on each violation, ok when clean.
---@param health table  the vim.health reporter
---@return nil
local function check_config(health)
    local problems = 0

    for _, field in ipairs({ "padding", "sticky" }) do
        if type(config[field]) ~= "boolean" then
            health.error(("%s must be a boolean (got %s)"):format(field, vim.inspect(config[field])))
            problems = problems + 1
        end
    end

    if type(config.mappings) ~= "table" then
        health.error(("mappings must be a table (got %s)"):format(type(config.mappings)))
        problems = problems + 1
    else
        for _, field in ipairs({ "basic", "extra" }) do
            if type(config.mappings[field]) ~= "boolean" then
                health.error(
                    ("mappings.%s must be a boolean (got %s)"):format(field, vim.inspect(config.mappings[field]))
                )
                problems = problems + 1
            end
        end
    end

    if type(config.languages) ~= "table" then
        health.error(("languages must be a table (got %s)"):format(type(config.languages)))
        problems = problems + 1
    else
        for lang, pair in pairs(config.languages) do
            if type(lang) ~= "string" or type(pair) ~= "table" then
                health.error(("languages[%s] must be a { line?, block? } table"):format(vim.inspect(lang)))
                problems = problems + 1
            else
                for _, side in ipairs({ "line", "block" }) do
                    local cs = pair[side]
                    if cs ~= nil and (type(cs) ~= "string" or not cs:find("%%s")) then
                        health.error(
                            ('languages["%s"].%s must be a string containing %%s (got %s)'):format(
                                lang,
                                side,
                                vim.inspect(cs)
                            )
                        )
                        problems = problems + 1
                    end
                end
            end
        end
    end

    if problems == 0 then
        health.ok("config valid")
    end
end

--- Run the health report.
---@return nil
function M.check()
    local health = vim.health
    health.start("lvim-comment")

    if vim.fn.has("nvim-0.12") == 1 then
        health.ok("Neovim >= 0.12")
    else
        health.error("Neovim >= 0.12 is required (the lvim-tech set targets 0.12)")
    end

    local ok_utils = pcall(require, "lvim-utils.utils")
    if ok_utils then
        health.ok("lvim-utils found (shared merge)")
    else
        health.warn("lvim-utils not found — falling back to tbl_deep_extend for setup()")
    end

    -- :checkhealth swaps its own scratch buffer in before the checks run, so the CURRENT
    -- buffer is never the user's file — parser and resolver are reported against the
    -- ALTERNATE buffer, the one checkhealth was started from.
    local bufnr = vim.fn.bufnr("#")
    local has_buf = bufnr > 0 and vim.api.nvim_buf_is_loaded(bufnr)
    if has_buf then
        local name = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":t")
        if name == "" then
            name = "[No Name]"
        end
        local ok_parser, parser = pcall(vim.treesitter.get_parser, bufnr)
        if ok_parser and parser then
            health.ok(
                ("treesitter parser attached to %s (%s) — embedded-language resolution active there"):format(
                    name,
                    parser:lang()
                )
            )
        else
            health.info(
                ("no treesitter parser for %s — resolution uses the filetype row / 'commentstring'"):format(name)
            )
        end
    end
    if not pcall(require, "lvim-ts") then
        health.info("lvim-ts not found (optional) — parsers are not auto-installed per filetype")
    end

    -- Mapping state — the headline check: a later plugin re-mapping gc/gb is invisible
    -- until a toggle does the wrong thing.
    if config.mappings.basic then
        check_map(health, "gc", "n")
        check_map(health, "gb", "n")
        check_map(health, "gcc", "n")
        check_map(health, "gbb", "n")
        check_map(health, "gc", "x")
        check_map(health, "gb", "x")
    else
        health.info("mappings.basic = false — Neovim's built-in gc set stays active (no gb/block support)")
    end
    if config.mappings.extra then
        check_map(health, "gco", "n")
        check_map(health, "gcO", "n")
        check_map(health, "gcA", "n")
    else
        health.info("mappings.extra = false — gco/gcO/gcA not installed")
    end

    -- What the resolver would use in the buffer checkhealth was started from.
    if has_buf then
        local pair = cstring.resolve(bufnr)
        if pair then
            health.info(
                ("resolved there: line=%s  block=%s"):format(
                    pair.line and ('"%s"'):format(pair.line) or "-",
                    pair.block and ('"%s"'):format(pair.block) or "- (blockwise falls back to linewise)"
                )
            )
        else
            health.warn("nothing resolves in that buffer — no table row and its 'commentstring' is empty")
        end
    else
        health.info("no alternate buffer — open a file and re-run to see the resolver's pick")
    end

    check_config(health)
end

return M
