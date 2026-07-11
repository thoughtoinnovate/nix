return {
    "folke/which-key.nvim",
    event = "VeryLazy",
    opts = {
        preset = "modern",
        delay = function()
            return vim.o.timeoutlen  -- Use the configured timeoutlen (300ms)
        end,
        -- Group names for better organization
        spec = {
            { "<leader>b", group = "Buffers" },
            { "<leader>c", group = "Code/Tests" },
            { "<leader>d", group = "Debug" },
            { "<leader>f", group = "Find/Format" },
            { "<leader>l", group = "List" },
            { "<leader>m", group = "Mason" },
            { "<leader>s", group = "Split" },
            { "<leader>t", group = "Tab/Terminal" },
            { "<leader>u", group = "UI/Toggle" },
            { "<leader>w", group = "Window" },
        },
    },
    keys = {
        {
            "<leader>?",
            function()
                require("which-key").show({ global = false })
            end,
            desc = "Buffer Local Keymaps (which-key)",
        },
    },
}
