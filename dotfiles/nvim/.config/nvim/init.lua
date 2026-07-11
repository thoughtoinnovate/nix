-- Prefer the Python supplied by the active Nix profile when available.
local python3 = vim.fn.exepath("python3")
if python3 ~= "" then
    vim.g.python3_host_prog = python3
end

require("vim-options")
require("config.lazy")
require("config.keymaps")

-- Load database connections
require("config.database_loader").load_connections()

-- Apply color scheme with persistence
-- Lazy-load theme_persistence only when needed
vim.schedule(function()
	local theme_persistence = require("core.theme_persistence")
	local saved_theme = theme_persistence.load_theme()

	-- If no saved theme, use catppuccin as default
	if not saved_theme then
		vim.cmd.colorscheme("catppuccin")
	end
end)

-- --------------------------------------
-- Global Diagnostic Appearance Configuration
-- --------------------------------------
vim.diagnostic.config({
	virtual_text = true, -- Enabled explicitly for 0.11+ [1]
	signs = {
		text = {
			[vim.diagnostic.severity.ERROR] = "",
			[vim.diagnostic.severity.WARN] = "",
			[vim.diagnostic.severity.INFO] = "",
			[vim.diagnostic.severity.HINT] = "",
		},
	},
	underline = true,
	update_in_insert = false,
	severity_sort = true,
	float = { border = "rounded" }, -- Border for diagnostic popups
})

-- Customize floating window borders for LSP handlers (global handlers)
vim.lsp.handlers["textDocument/hover"] = vim.lsp.with(vim.lsp.handlers.hover, { border = "rounded" })
vim.lsp.handlers["textDocument/signatureHelp"] = vim.lsp.with(vim.lsp.handlers.signature_help, { border = "rounded" })

-- --------------------------------------
-- Load Common LSP Configuration (Attach Logic, Keymaps, Completion)
-- --------------------------------------
-- This file contains the on_lsp_attach function and LspAttach autocommand
require("core.lsp_common")

-- --------------------------------------
-- Configure and Enable the Language Servers
-- --------------------------------------
-- Load custom LSP configurations from lsp/ directory
-- These servers have custom settings defined in their respective config files

-- Helper function to safely load LSP configs
local function load_lsp_config(server_name, config_path)
	local ok, config = pcall(require, config_path)
	if ok then
		vim.lsp.config(server_name, config)
	else
		vim.notify(
			string.format("Failed to load %s config: %s", server_name, config),
			vim.log.levels.WARN,
			{ title = "LSP Configuration" }
		)
	end
end

-- Load custom configurations with error handling
load_lsp_config("pyright", "lsp.pyright")
load_lsp_config("lua_ls", "lsp.lua_ls")
load_lsp_config("gopls", "lsp.gopls")
load_lsp_config("bashls", "lsp.bashls")
load_lsp_config("ts_ls", "lsp.ts_ls")

-- Enable all configured servers
-- Servers with custom configs (from lsp/ directory): pyright, lua_ls, gopls, bashls
-- Note: LSP servers are configured per-filetype in core/lsp_common.lua
-- Note: rust_analyzer is loaded only by rustaceanvim
-- Note: jdtls loaded by nvim-jdtls plugin for better Java support
