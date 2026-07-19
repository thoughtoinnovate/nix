-- ============================================================================
-- Indentation/Formatting/Linting Keybindings (Namespace: <leader>i)
-- ============================================================================

local keymap = vim.keymap.set

-- Linting state tracking
if vim.g.linting_enabled == nil then
	vim.g.linting_enabled = true -- Default to enabled
end

-- Linting
keymap("n", "<leader>il", function()
	if vim.g.linting_enabled then
		require("lint").try_lint()
	else
		print("Linting is disabled. Enable it with <leader>it")
	end
end, { desc = "Indent: Trigger Linting" })

keymap("n", "<leader>it", function()
	if vim.g.linting_enabled then
		-- Disable linting
		vim.g.linting_enabled = false
		vim.diagnostic.reset()
		print("✗ Linting disabled")
	else
		-- Enable linting
		vim.g.linting_enabled = true
		-- Run linting immediately on the current buffer
		require("lint").try_lint()
		print("✓ Linting enabled")
	end
end, { desc = "Indent: Toggle Linting" })

-- Format (also available in c.lua as <leader>cf)
keymap("n", "<leader>if", function()
	vim.lsp.buf.format({ async = true })
end, { desc = "Indent: Format Document" })
