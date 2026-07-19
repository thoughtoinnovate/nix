-- ============================================================================
-- Window Management Keybindings (Namespace: <leader>w)
-- ============================================================================

local keymap = vim.keymap.set

-- Split Creation
keymap("n", "<leader>wh", "<cmd>split<cr>", { desc = "Window: Split Horizontal" })
keymap("n", "<leader>wv", "<cmd>vsplit<cr>", { desc = "Window: Split Vertical" })

-- Window Control
keymap("n", "<leader>wc", "<cmd>close<cr>", { desc = "Window: Close Current" })
keymap("n", "<leader>wo", "<cmd>only<cr>", { desc = "Window: Close All Others" })
keymap("n", "<leader>w=", "<C-w>=", { desc = "Window: Equalize Sizes" })

-- Window Maximize/Restore
keymap("n", "<leader>wm", function()
	-- Check if current window is maximized (takes full height and width)
	local win_height = vim.api.nvim_win_get_height(0)
	local win_width = vim.api.nvim_win_get_width(0)
	local total_height = vim.o.lines - vim.o.cmdheight - 1 -- Account for statusline
	local total_width = vim.o.columns

	-- Consider window maximized if it's close to full size (within 5 chars/lines)
	if math.abs(win_height - total_height) < 5 and math.abs(win_width - total_width) < 5 then
		-- Window is maximized, equalize
		vim.cmd("wincmd =")
	else
		-- Maximize window
		vim.cmd("wincmd _ | wincmd |")
	end
end, { desc = "Window: Maximize/Restore Toggle" })
keymap("n", "<leader>wM", "<cmd>wincmd o<cr>", { desc = "Window: Maximize (Close Others)" })

-- Window Navigation (Ctrl+hjkl)
keymap("n", "<C-h>", "<C-w>h", { desc = "Window: Move to Left" })
keymap("n", "<C-j>", "<C-w>j", { desc = "Window: Move to Bottom" })
keymap("n", "<C-k>", "<C-w>k", { desc = "Window: Move to Top" })
keymap("n", "<C-l>", "<C-w>l", { desc = "Window: Move to Right" })

-- Window Resizing (Ctrl+arrows)
keymap("n", "<C-Up>", "<cmd>resize +2<cr>", { desc = "Window: Increase Height" })
keymap("n", "<C-Down>", "<cmd>resize -2<cr>", { desc = "Window: Decrease Height" })
keymap("n", "<C-Left>", "<cmd>vertical resize -2<cr>", { desc = "Window: Decrease Width" })
keymap("n", "<C-Right>", "<cmd>vertical resize +2<cr>", { desc = "Window: Increase Width" })

-- Window Resizing (Leader+arrows)
keymap("n", "<leader><Up>", "<cmd>resize +2<cr>", { desc = "Window: Increase Height" })
keymap("n", "<leader><Down>", "<cmd>resize -2<cr>", { desc = "Window: Decrease Height" })
keymap("n", "<leader><Left>", "<cmd>vertical resize +2<cr>", { desc = "Window: Increase Width" })
keymap("n", "<leader><Right>", "<cmd>vertical resize -2<cr>", { desc = "Window: Decrease Width" })

-- Window Resizing (Leader+Shift+arrows) - Large steps
keymap("n", "<leader><S-Up>", "<cmd>resize +10<cr>", { desc = "Window: Increase Height (Large)" })
keymap("n", "<leader><S-Down>", "<cmd>resize -10<cr>", { desc = "Window: Decrease Height (Large)" })
keymap("n", "<leader><S-Left>", "<cmd>vertical resize +10<cr>", { desc = "Window: Increase Width (Large)" })
keymap("n", "<leader><S-Right>", "<cmd>vertical resize -10<cr>", { desc = "Window: Decrease Width (Large)" })

-- Window Movement (move window itself)
keymap("n", "<leader>wH", "<C-w>H", { desc = "Window: Move to Far Left" })
keymap("n", "<leader>wJ", "<C-w>J", { desc = "Window: Move to Bottom" })
keymap("n", "<leader>wK", "<C-w>K", { desc = "Window: Move to Top" })
keymap("n", "<leader>wL", "<C-w>L", { desc = "Window: Move to Far Right" })

-- Window Rotation
keymap("n", "<leader>wr", "<C-w>r", { desc = "Window: Rotate Downwards" })
keymap("n", "<leader>wR", "<C-w>R", { desc = "Window: Rotate Upwards" })

-- Move Window to Tab
keymap("n", "<leader>wt", "<C-w>T", { desc = "Window: Move to New Tab" })

-- Additional Window Utilities
keymap("n", "<leader>ww", "<C-w>w", { desc = "Window: Cycle to Next" })
keymap("n", "<leader>wp", "<C-w>p", { desc = "Window: Goto Previous" })
