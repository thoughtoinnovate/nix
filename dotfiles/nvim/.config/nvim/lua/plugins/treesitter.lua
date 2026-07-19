return {
    "nvim-treesitter/nvim-treesitter",
    build = ":TSUpdate",
    config = function()
        local treesitterConfig = require("nvim-treesitter.configs")

        treesitterConfig.setup({
            ensure_installed = {
                "bash",
                "css",
                "dockerfile",
                "go",
                "html",
                "java",
                "javascript",
                "json",
                "latex",
                "lua",
                "markdown",
                "markdown_inline",
                "python",
                "rust",
                "scala",
                "sql",
                "toml",
                "tsx",
                "typescript",
                "vim",
                "vimdoc",
                "yaml",
            },
            highlight = { enable = true },
            indent = { enable = true },
        })
    end,
}
