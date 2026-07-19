return {
    -- Auto-pairs in insert mode
    {
        "echasnovski/mini.pairs",
        event = "InsertEnter",
        config = function()
            require("mini.pairs").setup()
        end,
    },
    -- Surround in normal/visual mode
    {
        "echasnovski/mini.surround",
        event = "VeryLazy",
        config = function()
            require("mini.surround").setup()
        end,
    },
    {
        "echasnovski/mini.diff",
        config = function()
            local diff = require("mini.diff")
            diff.setup({
                -- Enable Git diff source
                source = diff.gen_source.git(),
            })
        end,
    },

}
