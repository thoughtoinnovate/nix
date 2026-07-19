-- ============================================================================
-- Quick Help & Special Keybindings (Namespace: Special keys)
-- ============================================================================

local keymap = vim.keymap.set

-- Quick Keymap Help - Shows all keymaps with better layout
keymap("n", "<leader>?", function()
    require("snacks").picker.keymaps({
        preview = true,
        layout = {
            width = 0.95,
            height = 0.95,
            preview = {
                width = 0.5,
            },
        },
    })
end, { desc = "Help: Show All Keymaps" })

-- Alternative compact view without preview
keymap("n", "<leader>/", function()
    require("snacks").picker.keymaps({
        preview = false,
        layout = {
            width = 0.7,
            height = 0.9,
        },
    })
end, { desc = "Help: Show Keymaps (Compact)" })
