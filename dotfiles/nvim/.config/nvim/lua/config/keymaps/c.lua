-- ============================================================================
-- Code Operations Keybindings (Namespace: <leader>c)
-- ============================================================================

local keymap = vim.keymap.set

-- LSP Code Actions
keymap({ "n", "v" }, "<leader>ca", vim.lsp.buf.code_action, { desc = "Code: Action" })
keymap("n", "<leader>cr", vim.lsp.buf.rename, { desc = "Code: Rename Symbol" })
keymap("n", "<leader>cf", function()
	require("conform").format({ async = true })
end, { desc = "Code: Format Document" })
keymap("n", "<leader>cl", vim.lsp.codelens.run, { desc = "Code: Run CodeLens" })

-- Testing (Neotest)
-- Helper function to check if neotest is available for current filetype
local function has_neotest_adapter()
	local ok, neotest = pcall(require, "neotest")
	if not ok then
		return false
	end
	-- Check if current filetype has an adapter configured
	local ft = vim.bo.filetype
	-- Currently configured for Java only
	return ft == "java"
end

keymap("n", "<leader>ct", function()
	if has_neotest_adapter() then
		require("neotest").run.run()
	else
		vim.notify(
			"Neotest not configured for " .. vim.bo.filetype .. " (currently Java only)",
			vim.log.levels.WARN
		)
	end
end, { desc = "Code: Run Nearest Test" })

keymap("n", "<leader>cT", function()
	if has_neotest_adapter() then
		require("neotest").run.run(vim.fn.expand("%"))
	else
		vim.notify(
			"Neotest not configured for " .. vim.bo.filetype .. " (currently Java only)",
			vim.log.levels.WARN
		)
	end
end, { desc = "Code: Run Test File" })

keymap("n", "<leader>co", function()
	if has_neotest_adapter() then
		require("neotest").output.open({ enter = true })
	else
		vim.notify(
			"Neotest not configured for " .. vim.bo.filetype .. " (currently Java only)",
			vim.log.levels.WARN
		)
	end
end, { desc = "Code: Show Test Output" })

keymap("n", "<leader>cs", function()
	if has_neotest_adapter() then
		require("neotest").summary.toggle()
	else
		vim.notify(
			"Neotest not configured for " .. vim.bo.filetype .. " (currently Java only)",
			vim.log.levels.WARN
		)
	end
end, { desc = "Code: Toggle Test Summary" })

keymap("n", "<leader>cS", function()
	if has_neotest_adapter() then
		require("neotest").run.stop()
	else
		vim.notify(
			"Neotest not configured for " .. vim.bo.filetype .. " (currently Java only)",
			vim.log.levels.WARN
		)
	end
end, { desc = "Code: Stop Test" })
