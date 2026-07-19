-- ============================================================================
-- Buffer Operations Keybindings (Namespace: <leader>b)
-- ============================================================================

local keymap = vim.keymap.set

-- Buffer Navigation
keymap("n", "<leader>bn", "<cmd>bnext<cr>", { desc = "Buffer: Next" })
keymap("n", "<leader>bp", "<cmd>bprevious<cr>", { desc = "Buffer: Previous" })
keymap("n", "<TAB>", "<cmd>bnext<cr>", { desc = "Buffer: Next (Tab)" })
keymap("n", "<leader>bl", "<cmd>ls<cr>", { desc = "Buffer: List All" })

-- Quick Buffer Access (1-9)
for i = 1, 9 do
	keymap("n", "<leader>b" .. i, "<cmd>buffer " .. i .. "<cr>", { desc = "Buffer: Go to " .. i })
end

-- Buffer Management
keymap("n", "<leader>bd", "<cmd>bd<cr>", { desc = "Buffer: Delete Current" })
keymap("n", "<leader>bD", "<cmd>bd!<cr>", { desc = "Buffer: Force Delete Current" })
keymap("n", "<leader>bo", "<cmd>%bd|e#|bd#<cr>", { desc = "Buffer: Delete All Others" })
keymap("n", "<leader>ba", "<cmd>%bd<cr>", { desc = "Buffer: Delete All" })
keymap("n", "<leader>bw", "<cmd>%bw<cr>", { desc = "Buffer: Wipe All" })

-- Scratch Buffers (Snacks)
keymap("n", "<leader>bs", function()
	require("snacks").scratch()
end, { desc = "Buffer: Toggle Scratch" })
keymap("n", "<leader>bS", function()
	require("snacks").scratch.select()
end, { desc = "Buffer: Select Scratch" })

-- Quick Save/Quit
keymap({ "n", "i" }, "<C-s>", "<cmd>w<cr><esc>", { desc = "Buffer: Save" })
keymap("n", "<C-q>", "<cmd>q<cr>", { desc = "Buffer: Quit Window" })
