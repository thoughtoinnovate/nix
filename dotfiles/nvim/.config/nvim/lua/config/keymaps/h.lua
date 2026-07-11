-- ============================================================================
-- Help/Utility Keybindings (Namespace: <leader>h)
-- ============================================================================

local keymap = vim.keymap.set

-- Clear Search Highlighting
keymap("n", "<leader>h", "<cmd>nohlsearch<cr>", { desc = "Help: Clear Search Highlight" })
keymap("n", "<leader>hc", "<cmd>nohlsearch<cr>", { desc = "Help: Clear Search Highlight" })

-- Show Messages
keymap("n", "<leader>hm", "<cmd>messages<cr>", { desc = "Help: Show Messages" })

-- Jump Navigation
keymap("n", "<leader>h[", "<C-o>", { desc = "Help: Jump to Previous Location" })
keymap("n", "<leader>h]", "<C-i>", { desc = "Help: Jump to Next Location" })

-- Terminal Mode Exit
keymap("t", "<C-n>", "<C-\\><C-n>", { desc = "Help: Exit Terminal Mode" })
