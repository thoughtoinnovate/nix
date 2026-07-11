-- ============================================================================
-- Zen Mode Keybindings (Namespace: <leader>z)
-- ============================================================================

local keymap = vim.keymap.set

-- Zen Mode (Snacks)
keymap("n", "<leader>zz", function()
	require("snacks").zen()
end, { desc = "Zen: Toggle Zen Mode" })

keymap("n", "<leader>zZ", function()
	require("snacks").zen.zoom()
end, { desc = "Zen: Toggle Zoom" })

-- Zen with specific settings
keymap("n", "<leader>zm", function()
	require("snacks").zen({ width = 0.6 })
end, { desc = "Zen: Medium Width" })

keymap("n", "<leader>zw", function()
	require("snacks").zen({ width = 0.8 })
end, { desc = "Zen: Wide Width" })

keymap("n", "<leader>zn", function()
	require("snacks").zen({ width = 0.5 })
end, { desc = "Zen: Narrow Width" })
