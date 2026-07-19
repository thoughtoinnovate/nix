-- ============================================================================
-- Jump Operations Keybindings (Namespace: <leader>j)
-- ============================================================================

local keymap = vim.keymap.set

-- Basic Navigation
keymap("n", "<leader>jn", "<C-i>", { desc = "Jump: Next" })
keymap("n", "<leader>jp", "<C-o>", { desc = "Jump: Previous" })

-- Quickfix List
keymap("n", "<leader>jqn", "<cmd>cnext<cr>", { desc = "Jump: Quickfix Next" })
keymap("n", "<leader>jqp", "<cmd>cprev<cr>", { desc = "Jump: Quickfix Previous" })

-- Location List
keymap("n", "<leader>jln", "<cmd>lnext<cr>", { desc = "Jump: Location Next" })
keymap("n", "<leader>jlp", "<cmd>lprev<cr>", { desc = "Jump: Location Previous" })

-- Buffer List
keymap("n", "<leader>jbn", "<cmd>bnext<cr>", { desc = "Jump: Buffer Next" })
keymap("n", "<leader>jbp", "<cmd>bprev<cr>", { desc = "Jump: Buffer Previous" })

-- Tab List
keymap("n", "<leader>jtn", "<cmd>tabnext<cr>", { desc = "Jump: Tab Next" })
keymap("n", "<leader>jtp", "<cmd>tabprev<cr>", { desc = "Jump: Tab Previous" })
