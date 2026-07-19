return {
	"thoughtoinnovate/tark",
	enabled = false,  -- Disabled due to Space key delay in Insert mode
	lazy = false,
	keys = {
		{ "<leader>ta", "<cmd>TarkChatToggle<cr>", desc = "Toggle tark chat" },
		{ "<leader>tag", "<cmd>TarkGhostToggle<cr>", desc = "Toggle ghost text" },
		{ "<leader>tas", "<cmd>TarkServerStatus<cr>", desc = "Server status" },
		{ "<leader>taf", "<cmd>TarkMaximize<cr>", desc = "Server status" },
	},
	opts = {
		server = { channel = "stable" },
	},
}
