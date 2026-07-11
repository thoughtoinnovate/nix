return {
    {
        'mrcjkb/rustaceanvim',
        version = '^6', -- Recommended
        lazy = false, -- This plugin is already lazy
        config = function()
            -- Configure rustaceanvim after it loads
            vim.g.rustaceanvim = {
                -- Enable inlay hints by default
                tools = {
                    inlay_hints = {
                        auto = true,
                    },
                },
                -- LSP configuration
                server = {
                    default_settings = {
                        ['rust-analyzer'] = {
                            -- Enable inlay hints in rust-analyzer
                            inlayHints = {
                                bindingModeHints = {
                                    enable = false,
                                },
                                chainingHints = {
                                    enable = true,
                                },
                                closingBraceHints = {
                                    enable = true,
                                    minLines = 25,
                                },
                                closureReturnTypeHints = {
                                    enable = "never",
                                },
                                lifetimeElisionHints = {
                                    enable = "never",
                                    useParameterNames = false,
                                },
                                maxLength = 25,
                                parameterHints = {
                                    enable = true,
                                },
                                reborrowHints = {
                                    enable = "never",
                                },
                                renderColons = true,
                                typeHints = {
                                    enable = true,
                                    hideClosureInitialization = false,
                                    hideNamedConstructor = false,
                                },
                            },
                        },
                    },
                },
            }
        end,
    },
    -- Crates.nvim for Cargo.toml management
    {
        "saecki/crates.nvim",
        ft = { "rust", "toml" },
        config = function(_, opts)
            local crates = require('crates')
            crates.setup(opts)
            
            -- Crates-specific keymaps
            vim.keymap.set("n", "<leader>ct", crates.toggle, { silent = true, desc = "Crates: Toggle" })
            vim.keymap.set("n", "<leader>cr", crates.reload, { silent = true, desc = "Crates: Reload" })
            vim.keymap.set("n", "<leader>cv", crates.show_versions_popup, { silent = true, desc = "Crates: Show Versions" })
            vim.keymap.set("n", "<leader>cf", crates.show_features_popup, { silent = true, desc = "Crates: Show Features" })
            vim.keymap.set("n", "<leader>cd", crates.show_dependencies_popup, { silent = true, desc = "Crates: Show Dependencies" })
            vim.keymap.set("n", "<leader>cu", crates.update_crate, { silent = true, desc = "Crates: Update Crate" })
            vim.keymap.set("v", "<leader>cu", crates.update_crates, { silent = true, desc = "Crates: Update Crates" })
            vim.keymap.set("n", "<leader>cU", crates.upgrade_crate, { silent = true, desc = "Crates: Upgrade Crate" })
            vim.keymap.set("v", "<leader>cU", crates.upgrade_crates, { silent = true, desc = "Crates: Upgrade Crates" })
            vim.keymap.set("n", "<leader>cH", crates.open_homepage, { silent = true, desc = "Crates: Open Homepage" })
            vim.keymap.set("n", "<leader>cR", crates.open_repository, { silent = true, desc = "Crates: Open Repository" })
            vim.keymap.set("n", "<leader>cD", crates.open_documentation, { silent = true, desc = "Crates: Open Documentation" })
            vim.keymap.set("n", "<leader>cC", crates.open_crates_io, { silent = true, desc = "Crates: Open Crates.io" })
        end,
    },
}
