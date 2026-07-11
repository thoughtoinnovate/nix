-- ============================================================================
-- UI/Themes Keybindings (Namespace: <leader>u)
-- ============================================================================

local keymap = vim.keymap.set

-- Theme Management
keymap("n", "<leader>ut", function()
	require("core.theme_persistence").theme_selector()
end, { desc = "UI: Theme Selector" })

keymap("n", "<leader>us", function()
	require("core.theme_persistence").theme_selector()
end, { desc = "UI: Select Theme" })

keymap("n", "<leader>uc", function()
	local theme = vim.g.colors_name or "unknown"
	print("Current theme: " .. theme)
end, { desc = "UI: Show Current Theme" })

-- UI Toggles
keymap("n", "<leader>uz", function()
	require("snacks").zen.zoom()
end, { desc = "UI: Toggle Zoom" })

keymap("n", "<leader>un", function()
	require("snacks").notifier.hide()
end, { desc = "UI: Dismiss Notifications" })

-- Database UI
keymap("n", "<leader>ud", "<cmd>DBUIToggle<cr>", { desc = "UI: Toggle Database UI" })
keymap("n", "<leader>uD", "<cmd>DBUIFindBuffer<cr>", { desc = "UI: Database Find Buffer" })

-- Display Toggles
keymap("n", "<leader>ul", "<cmd>set list!<cr>", { desc = "UI: Toggle Listchars" })
keymap("n", "<leader>uw", "<cmd>set wrap!<cr>", { desc = "UI: Toggle Line Wrap" })
keymap("n", "<leader>uN", "<cmd>set number!<cr>", { desc = "UI: Toggle Line Numbers" })
keymap("n", "<leader>ur", "<cmd>set relativenumber!<cr>", { desc = "UI: Toggle Relative Numbers" })
keymap("n", "<leader>ub", function()
	if vim.o.background == "dark" then
		vim.o.background = "light"
	else
		vim.o.background = "dark"
	end
end, { desc = "UI: Toggle Background" })

-- Colorcolumn Toggle
keymap("n", "<leader>uu", function()
	if vim.wo.colorcolumn == "" then
		vim.wo.colorcolumn = "80"
	else
		vim.wo.colorcolumn = ""
	end
end, { desc = "UI: Toggle Color Column" })
