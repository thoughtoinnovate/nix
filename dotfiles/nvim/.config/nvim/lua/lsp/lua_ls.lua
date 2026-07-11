return {
    cmd = { 'lua-language-server' },   -- Adjust if installed differently or not in PATH
    root_markers = { '.git', 'lua/' }, -- Common markers for Lua projects/plugins
    filetypes = { 'lua' },
    settings = {
        Lua = {
            runtime = {
                version = 'LuaJIT', -- Neovim uses LuaJIT
                -- Use Neovim's runtime path finding logic
                path = vim.split(package.path, ';'),
                -- You might need to add paths specific to your plugin manager if runtime files are elsewhere
                -- path = vim.list_extend(vim.split(package.path, ';'), { '/path/to/plugin/manager/lua/?/init.lua', '/path/to/plugin/manager/lua/?.lua' })
            },
            diagnostics = {
                globals = { 'vim' },
                -- Disable diagnostics for undefined globals if they are known (e.g., from plugins)
                -- disable = { "undefined-global" },
            },
            workspace = {
                -- Add Neovim runtime files to the workspace library for completion/diagnostics
                library = vim.api.nvim_get_runtime_file("", true),
                -- Set maxPreload to avoid excessive loading times on large projects
                maxPreload = 2000,
                preloadFileSize = 1000,
                -- Don't complain about require statements for plugins not using EmmyLua annotations
                checkThirdParty = false,
            },
            -- Disable telemetry (optional but recommended)
            telemetry = {
                enable = false,
            },
        },
    },
}
