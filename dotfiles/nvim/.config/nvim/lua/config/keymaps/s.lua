-- ============================================================================
-- Session Management Keybindings (Namespace: <leader>s)
-- ============================================================================

local keymap = vim.keymap.set

-- Auto-Session Management
keymap("n", "<leader>ss", "<cmd>AutoSession save<cr>", { desc = "Session: Save" })
keymap("n", "<leader>sl", "<cmd>AutoSession restore<cr>", { desc = "Session: Load/Restore" })
keymap("n", "<leader>sd", "<cmd>AutoSession delete<cr>", { desc = "Session: Delete" })
keymap("n", "<leader>sf", "<cmd>AutoSession search<cr>", { desc = "Session: Find/Search" })
keymap("n", "<leader>sD", "<cmd>AutoSession disable<cr>", { desc = "Session: Disable Auto-Save" })
keymap("n", "<leader>sT", "<cmd>AutoSession toggle<cr>", { desc = "Session: Toggle Auto-Save" })

-- Clear All Sessions
keymap("n", "<leader>sc", function()
	vim.ui.input({ prompt = "Clear all sessions? (y/n): " }, function(input)
		if input == "y" or input == "Y" then
			vim.fn.system("rm -rf " .. vim.fn.stdpath("data") .. "/sessions/*")
			vim.notify("Cleared all sessions", vim.log.levels.INFO)
		end
	end)
end, { desc = "Session: Clear All" })
