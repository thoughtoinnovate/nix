-- ============================================================================
-- Notifications Keybindings (Namespace: <leader>n)
-- ============================================================================

local keymap = vim.keymap.set

-- Notification Management (Snacks)
keymap("n", "<leader>nh", function()
	require("snacks").notifier.show_history()
end, { desc = "Notifications: Show History" })

keymap("n", "<leader>nd", function()
	require("snacks").notifier.hide()
end, { desc = "Notifications: Dismiss All" })

keymap("n", "<leader>nl", function()
	require("snacks").notifier.show_last()
end, { desc = "Notifications: Show Last" })
