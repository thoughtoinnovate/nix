-- ============================================================================
-- Tab/Terminal Keybindings (Namespace: <leader>t)
-- ============================================================================

local keymap = vim.keymap.set

-- Tab Management
keymap("n", "<leader>tn", "<cmd>tabnew<cr>", { desc = "Tab: New" })
keymap("n", "<leader>tc", "<cmd>tabclose<cr>", { desc = "Tab: Close" })
keymap("n", "<leader>to", "<cmd>tabonly<cr>", { desc = "Tab: Close All Others" })
keymap("n", "<leader>t]", "<cmd>tabnext<cr>", { desc = "Tab: Next" })
keymap("n", "<leader>t[", "<cmd>tabprevious<cr>", { desc = "Tab: Previous" })
keymap("n", "<leader>tl", "<cmd>tablast<cr>", { desc = "Tab: Go to Last" })
keymap("n", "<leader>tf", "<cmd>tabfirst<cr>", { desc = "Tab: Go to First" })

-- Terminal (Snacks)
keymap("n", "<leader>tt", function()
	require("snacks").terminal()
end, { desc = "Terminal: Toggle" })

keymap("n", "<leader>tT", function()
	require("snacks").terminal(nil, { cwd = vim.fn.getcwd() })
end, { desc = "Terminal: Toggle (CWD)" })

keymap("n", "<leader>tv", function()
	require("snacks").terminal(nil, { win = { position = "right" } })
end, { desc = "Terminal: Open Vertical Split" })

keymap("n", "<leader>th", function()
	require("snacks").terminal(nil, { win = { position = "bottom" } })
end, { desc = "Terminal: Open Horizontal Split" })

-- Lazygit Terminal
keymap("n", "<leader>tg", function()
	require("snacks").lazygit()
end, { desc = "Terminal: Lazygit" })

-- Terminal Mode Keybindings
keymap("t", "<C-/>", "<cmd>close<cr>", { desc = "Terminal: Close" })

-- Global Terminal Toggle (from Snacks)
keymap({ "n", "t" }, "<c-/>", function()
	require("snacks").terminal()
end, { desc = "Terminal: Toggle (Global)" })
keymap({ "n", "t" }, "<c-_>", function()
	require("snacks").terminal()
end, { desc = "Terminal: Toggle (Global Alt)" })
