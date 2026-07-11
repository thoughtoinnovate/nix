return {
    {
        "williamboman/mason.nvim",
        config = function()
            require("mason").setup()
        end,
    },
    {
        "williamboman/mason-lspconfig.nvim",
        lazy = false,
        opts = {
            auto_install = false,
        },
        config = function()
            require("mason-lspconfig").setup({
                -- Common servers are supplied by Nix. Mason remains available
                -- for explicit, optional installs through :Mason.
                ensure_installed = {},
            })
        end,
    },
    -- nvim-lspconfig is no longer needed with Neovim 0.11+ built-in vim.lsp API
    -- Keeping it commented for reference in case you want to add servers not in lsp/ directory
    -- {
    --     "neovim/nvim-lspconfig",
    -- },
}
