-- ============================================================================
-- Explorer/File Manager Keybindings (Namespace: <leader>e)
-- ============================================================================

local keymap = vim.keymap.set

-- Oil File Explorer
keymap("n", "<leader>eo", "<cmd>Oil<cr>", { desc = "Explorer: Open Oil" })
keymap("n", "<leader>ef", "<cmd>Oil --float<cr>", { desc = "Explorer: Open Oil (Float)" })
keymap("n", "-", "<cmd>Oil<cr>", { desc = "Explorer: Open Parent Directory" })

-- Oil Utilities
keymap("n", "<leader>eh", function()
	require("oil").toggle_hidden()
end, { desc = "Explorer: Toggle Hidden Files" })

keymap("n", "<leader>er", function()
	-- Oil auto-refreshes, but we can manually trigger by saving and reopening
	local oil = require("oil")
	if oil.get_current_dir() then
		-- Discard changes and refresh
		vim.cmd("edit")
	else
		vim.notify("Not in an Oil buffer", vim.log.levels.WARN)
	end
end, { desc = "Explorer: Refresh Oil" })

-- Alternative: Use Oil's built-in actions
keymap("n", "<leader>eR", "<cmd>Oil<cr>", { desc = "Explorer: Reload Oil" })

-- Snacks Explorer
keymap("n", "<leader>es", function()
	require("snacks").explorer()
end, { desc = "Explorer: Snacks Explorer" })
