-- ============================================================================
-- Yank/Clipboard Operations Keybindings (Namespace: <leader>y)
-- ============================================================================

local keymap = vim.keymap.set

-- Yank to System Clipboard
keymap("v", "<leader>y", '"+y', { desc = "Yank: To System Clipboard" })
keymap("n", "<leader>Y", '"+Y', { desc = "Yank: Line to System Clipboard" })
keymap("n", "<leader>yy", '"+yy', { desc = "Yank: Line to System Clipboard" })

-- Yank entire file
keymap("n", "<leader>ya", "gg\"+yG", { desc = "Yank: Entire File to System Clipboard" })

-- Paste from System Clipboard
keymap({ "n", "v" }, "<leader>p", '"+p', { desc = "Yank: Paste from System Clipboard" })
keymap({ "n", "v" }, "<leader>P", '"+P', { desc = "Yank: Paste Before from System Clipboard" })

-- Delete without yanking
keymap({ "n", "v" }, "<leader>yd", '"_d', { desc = "Yank: Delete Without Yanking" })
keymap("v", "<leader>yP", '"_dP', { desc = "Yank: Replace Without Yanking Deleted" })

-- Yank file path
keymap("n", "<leader>yf", function()
	local path = vim.fn.expand("%:p")
	vim.fn.setreg("+", path)
	print("Yanked file path: " .. path)
end, { desc = "Yank: File Path (Absolute)" })

keymap("n", "<leader>yr", function()
	local path = vim.fn.expand("%:.")
	vim.fn.setreg("+", path)
	print("Yanked relative path: " .. path)
end, { desc = "Yank: File Path (Relative)" })

keymap("n", "<leader>yn", function()
	local name = vim.fn.expand("%:t")
	vim.fn.setreg("+", name)
	print("Yanked file name: " .. name)
end, { desc = "Yank: File Name" })
