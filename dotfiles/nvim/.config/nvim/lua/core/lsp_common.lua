-- Common LSP configuration logic (LspAttach, Keymaps, Completion)

-- Create an autocommand group to organize LSP attach actions
local lsp_attach_group = vim.api.nvim_create_augroup('UserLspConfig', { clear = true })

-- Configure LSP servers per filetype (Neovim 0.11+ approach)
local function setup_lsp_servers()
    local server_filetypes = {
        pyright = { "python" },
        lua_ls = { "lua" },
        gopls = { "go" },
        bashls = { "sh", "bash", "zsh" },
        ts_ls = { "javascript", "typescript", "javascriptreact", "typescriptreact" },
        html = { "html" },
        emmet_ls = { "html" },
        cssls = { "css", "scss", "less" },
        tailwindcss = { "css", "scss", "less" },
        dockerls = { "dockerfile" },
        docker_compose_language_service = { "yaml.docker-compose" },
        jsonls = { "json" },
        yamlls = { "yaml" },
        taplo = { "toml" },
        lemminx = { "xml" },
        sqlls = { "sql" },
        marksman = { "markdown" },
        jdtls = { "java" },  -- Add Java LSP
    }

    for server, filetypes in pairs(server_filetypes) do
        vim.api.nvim_create_autocmd("FileType", {
            pattern = filetypes,
            callback = function(args)
                -- Skip jdtls as it's handled by nvim-jdtls plugin
                if server ~= "jdtls" then
                    vim.lsp.enable(server, { bufnr = args.buf })
                end
            end,
        })
    end
end

-- Initialize LSP servers
setup_lsp_servers()

-- Define the callback function for LspAttach
local on_lsp_attach = function(ev)
    local client = vim.lsp.get_client_by_id(ev.data.client_id)
    local buf = ev.buf

    -- Highlight yank
    vim.api.nvim_create_autocmd('TextYankPost', {
        desc = 'Highlight yanking when copying text!',
        group = vim.api.nvim_create_augroup('hightlightYank', { clear = true }),
        callback = function()
            vim.highlight.on_yank()
        end
    })

    -- LSP keymaps are now set globally in config.keymaps.g (go-to navigation)
    -- No buffer-local keymaps needed here

    -- Only enable document highlighting if the server supports it
    if client and client:supports_method('textDocument/documentHighlight') then
        vim.api.nvim_create_autocmd('CursorHold', {
            buffer = buf,
            group = lsp_attach_group,
            callback = function() vim.lsp.buf.document_highlight() end,
        })
        vim.api.nvim_create_autocmd('CursorMoved', {
            buffer = buf,
            group = lsp_attach_group,
            callback = function() vim.lsp.buf.clear_references() end,
        })
    end

    -- Set other buffer-local settings if needed based on client capabilities
    if client and client:supports_method('textDocument/foldingRange') then
        vim.opt_local.foldmethod = 'expr'
        vim.opt_local.foldexpr = 'vim.lsp.foldexpr()'
        vim.opt_local.foldenable = false -- Don't fold automatically on open
    end
end

-- Attach the callback to the LspAttach event using the defined group
vim.api.nvim_create_autocmd('LspAttach', {
    group = lsp_attach_group,
    callback = on_lsp_attach,
})
