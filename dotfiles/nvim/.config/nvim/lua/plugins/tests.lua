return {
    {
        "nvim-neotest/neotest",
        dependencies = {
            "rcasia/neotest-java", -- Java adapter
            "nvim-lua/plenary.nvim",
            "nvim-treesitter/nvim-treesitter",
            "nvim-neotest/nvim-nio",
        },
        ft = { "java" },
        config = function()
            require("neotest").setup({
                adapters = {
                    require("neotest-java")({
                        -- If you want to explicitly enable debugging
                        dap = { justMyCode = true }, -- optional
                    }),
                },
                quickfix = {
                    open = false,
                },
            })
        end,
    },
}
