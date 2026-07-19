return {
    {
        "folke/noice.nvim",
        event = "VeryLazy",
        opts = {
            lsp = {
                override = {
                    ["vim.lsp.util.convert_input_to_markdown_lines"] = true,
                    ["vim.lsp.util.stylize_markdown"] = true,
                    ["cmp.entry.get_documentation"] = true,
                },
                progress = {
                    enabled = true,
                    format = "lsp_progress",
                    format_done = "lsp_progress_done",
                    throttle = 200,
                    view = "mini",
                },
            },
            -- Move notifications to top-right corner
            views = {
                notify = {
                    replace = true,
                },
            },
            routes = {
                {
                    view = "notify",
                    filter = { event = "msg_showmode" },
                },
            },
            presets = {
                bottom_search = true,
                command_palette = true,
                long_message_to_split = true,
                inc_rename = false,
                lsp_doc_border = false,
            },
        },
        dependencies = {
            "MunifTanjim/nui.nvim",
            "rcarriga/nvim-notify",
        },
        config = function(_, opts)
            require("noice").setup(opts)
            -- Configure nvim-notify to appear in top-right
            require("notify").setup({
                stages = "fade",
                timeout = 2000,
                top_down = true,
                render = "compact",
                max_width = 50,
            })
        end,
    }
}
