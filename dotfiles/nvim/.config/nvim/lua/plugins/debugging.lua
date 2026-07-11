return {
    "mfussenegger/nvim-dap",
    dependencies = {
        "rcarriga/nvim-dap-ui",
        "mfussenegger/nvim-jdtls",
        "nvim-telescope/telescope-dap.nvim",
        -- optional for virtual text
        "theHamsta/nvim-dap-virtual-text",
        --lua Debugger
        -- "jbyuki/one-small-step-for-vimkind"
    },
    config = function()
        local dap = require("dap")
        local dapui = require("dapui")
        local python = vim.fn.exepath("python3")
        require("lazydev").setup({
            library = { "nvim-dap-ui" },
        })
        require("dapui").setup()
        require("nvim-dap-virtual-text").setup()

        -- open dap ui automatically
        dap.listeners.before.attach.dapui_config = function()
            dapui.open()
        end
        dap.listeners.before.launch.dapui_config = function()
            dapui.open()
        end
        dap.listeners.before.event_terminated.dapui_config = function()
            dapui.close()
        end
        dap.listeners.before.event_exited.dapui_config = function()
            dapui.close()
        end

        -- Java dap configs (only if jdtls is available)
        pcall(function()
            require("jdtls.dap").setup_dap_main_class_configs()
            require("jdtls").setup_dap({ hotcodereplace = "auto" })
        end)


        -- lua dap configs
        dap.configurations.lua = {
            {
                type = 'nlua',
                request = 'attach',
                name = "Attach to running Neovim instance",
            }
        }
        dap.adapters.nlua = function(callback, config)
            callback({ type = 'server', host = config.host or "127.0.0.1", port = config.port or 8086 })
        end

        -- Python dap configs
        dap.adapters.python = {
            type = 'executable',
            command = python ~= '' and python or 'python3',
            args = { '-m', 'debugpy.adapter' },
        }
        dap.configurations.python = {
            {
                type = 'python',
                request = 'launch',
                name = "Launch file",
                program = "${file}",
                pythonPath = function()
                    -- Try to detect virtual environment
                    local cwd = vim.fn.getcwd()
                    if vim.fn.executable(cwd .. '/venv/bin/python') == 1 then
                        return cwd .. '/venv/bin/python'
                    elseif vim.fn.executable(cwd .. '/.venv/bin/python') == 1 then
                        return cwd .. '/.venv/bin/python'
                    else
                        -- Use python3 from PATH, fallback to python
                        return vim.fn.exepath('python3') ~= '' and vim.fn.exepath('python3') or vim.fn.exepath('python')
                    end
                end,
            },
            {
                type = 'python',
                request = 'launch',
                name = "Launch file with arguments",
                program = "${file}",
                args = function()
                    local args_string = vim.fn.input('Arguments: ')
                    return vim.split(args_string, " +")
                end,
                pythonPath = function()
                    local cwd = vim.fn.getcwd()
                    if vim.fn.executable(cwd .. '/venv/bin/python') == 1 then
                        return cwd .. '/venv/bin/python'
                    elseif vim.fn.executable(cwd .. '/.venv/bin/python') == 1 then
                        return cwd .. '/.venv/bin/python'
                    else
                        -- Use python3 from PATH, fallback to python
                        return vim.fn.exepath('python3') ~= '' and vim.fn.exepath('python3') or vim.fn.exepath('python')
                    end
                end,
            },
            {
                type = 'python',
                request = 'attach',
                name = 'Attach remote',
                connect = function()
                    local host = vim.fn.input('Host [127.0.0.1]: ')
                    host = host ~= '' and host or '127.0.0.1'
                    local port = tonumber(vim.fn.input('Port [5678]: ')) or 5678
                    return { host = host, port = port }
                end,
            },
        }

        -- JavaScript/TypeScript dap configs
        local js_debug = vim.fn.exepath("js-debug")
        if js_debug ~= "" then
            dap.adapters["pwa-node"] = {
                type = "server",
                host = "localhost",
                port = "${port}",
                executable = {
                    command = js_debug,
                    args = { "${port}" },
                }
            }
        end

        for _, language in ipairs({ "typescript", "javascript", "typescriptreact", "javascriptreact" }) do
            dap.configurations[language] = {
                {
                    type = "pwa-node",
                    request = "launch",
                    name = "Launch file",
                    program = "${file}",
                    cwd = "${workspaceFolder}",
                },
                {
                    type = "pwa-node",
                    request = "attach",
                    name = "Attach",
                    processId = require('dap.utils').pick_process,
                    cwd = "${workspaceFolder}",
                },
            }
        end
    end,
}
