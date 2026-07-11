local function require_executable(name)
    local executable = vim.fn.exepath(name)
    if executable == "" then
        vim.notify(name .. " is unavailable; enable the Nix development profile", vim.log.levels.ERROR)
        return nil
    end
    return executable
end

-- Clear undo history after jupytext converts ipynb to prevent undoing to raw JSON
vim.api.nvim_create_autocmd("BufReadPost", {
    pattern = "*.ipynb",
    callback = function()
        vim.bo.undolevels = -1
        vim.cmd([[exe "normal! a \<BS>\<Esc>"]])
        vim.bo.undolevels = 1000
        vim.bo.modified = false
    end,
})

vim.api.nvim_create_user_command("JupyterInstallDeps", function()
    vim.notify("Jupyter dependencies are managed by the Nix development profile", vim.log.levels.INFO)
end, { desc = "Explain how Jupyter dependencies are installed" })

vim.api.nvim_create_user_command("JupyterLab", function()
    local jupyter = require_executable("jupyter")
    if jupyter then
        vim.cmd("split | terminal " .. vim.fn.shellescape(jupyter) .. " lab")
    end
end, { desc = "Launch JupyterLab in browser" })

vim.api.nvim_create_user_command("NewNotebook", function(opts)
    local filename = opts.args ~= "" and opts.args or "notebook"
    filename = filename:gsub("%.ipynb$", ""):gsub("%.py$", "") .. ".ipynb"
    local filepath
    if filename:match("^/") or filename:match("^~") then
        filepath = vim.fn.expand(filename)
    else
        local dir = vim.fn.expand("%:p:h"):gsub("^oil://", "")
        if dir == "" then dir = vim.fn.getcwd() end
        filepath = dir .. "/" .. filename
    end
    local lines = {
        '{',
        ' "cells": [',
        '  {"cell_type": "markdown", "id": "cell-1", "metadata": {}, "source": ["# Notebook Title"]},',
        '  {"cell_type": "code", "id": "cell-2", "execution_count": null, "metadata": {}, "outputs": [], "source": ["print(\\"Hello, World!\\")"]}',
        ' ],',
        ' "metadata": {"kernelspec": {"display_name": "Python 3", "language": "python", "name": "python3"}, "language_info": {"name": "python", "version": "3.11"}},',
        ' "nbformat": 4,',
        ' "nbformat_minor": 5',
        '}',
    }
    vim.fn.writefile(lines, filepath)
    vim.cmd("edit " .. filepath)
end, { nargs = "?", desc = "Create new Jupyter notebook with boilerplate" })

vim.keymap.set("n", "<leader>;C", function()
    vim.ui.input({ prompt = "Notebook name: " }, function(filename)
        if filename and filename ~= "" then
            vim.cmd("NewNotebook " .. filename)
        end
    end)
end, { desc = "Jupyter: Create new notebook" })

vim.api.nvim_create_user_command("JupyterRegisterVenv", function()
    local cwd = vim.fn.getcwd()
    local venv = cwd .. "/venv/bin/python"
    if vim.fn.filereadable(venv) == 0 then
        venv = cwd .. "/.venv/bin/python"
    end
    if vim.fn.filereadable(venv) == 0 then
        vim.notify("No venv found in project root", vim.log.levels.ERROR)
        return
    end
    local name = vim.fn.fnamemodify(cwd, ":t")
    local cmd = venv .. " -m pip install ipykernel && " .. venv .. " -m ipykernel install --user --name " .. name
    vim.cmd("split | terminal " .. cmd)
end, { desc = "Register project venv as Jupyter kernel" })

if vim.g.jupyter_cache_run_mode == nil then
    vim.g.jupyter_cache_run_mode = "conservative" -- "off" | "conservative"
end

local cell_cache = {}

local function split_percent_cells(bufnr)
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local cells, start = {}, 1

    for i, line in ipairs(lines) do
        if line:match("^# %%") then
            if start < i then table.insert(cells, { start = start, finish = i - 1 }) end
            start = i + 1
        end
    end
    if start <= #lines then table.insert(cells, { start = start, finish = #lines }) end

    return cells
end

local function get_cell_hash(bufnr, cell)
    local lines = vim.api.nvim_buf_get_lines(bufnr, cell.start - 1, cell.finish, false)
    return vim.fn.sha256(table.concat(lines, "\n"))
end

local function get_kernel_key()
    local kernels = vim.trim(vim.fn.MoltenStatusLineKernels(true) or "")
    if kernels == "" then
        return "default"
    end
    return kernels
end

local function get_scope_end_index(cells, cursor_line)
    local last_index = 0
    for i, cell in ipairs(cells) do
        if cell.finish <= cursor_line then
            last_index = i
        elseif cell.start <= cursor_line then
            last_index = i
            break
        else
            break
        end
    end
    return last_index
end

local function run_cells_with_cache(scope)
    local bufnr = vim.api.nvim_get_current_buf()
    local cells = split_percent_cells(bufnr)
    if #cells == 0 then
        return
    end

    local scope_end = #cells
    if scope == "to_cursor" then
        scope_end = get_scope_end_index(cells, vim.fn.line("."))
        if scope_end == 0 then
            return
        end
    end

    local mode = vim.g.jupyter_cache_run_mode
    local kernel_key = get_kernel_key()
    local buf_cache = cell_cache[bufnr] or {}
    local prev_hashes = buf_cache[kernel_key] or {}
    local next_hashes = vim.deepcopy(prev_hashes)
    local first_changed = nil

    for i = 1, scope_end do
        local hash = get_cell_hash(bufnr, cells[i])
        next_hashes[i] = hash
        if first_changed == nil and hash ~= prev_hashes[i] then
            first_changed = i
        end
    end
    if scope == "all" then
        for i = #cells + 1, #next_hashes do
            next_hashes[i] = nil
        end
    end

    if mode == "off" then
        first_changed = 1
    elseif first_changed == nil then
        buf_cache[kernel_key] = next_hashes
        cell_cache[bufnr] = buf_cache
        return
    end

    for i = first_changed, scope_end do
        vim.fn.MoltenEvaluateRange(cells[i].start, cells[i].finish)
    end

    buf_cache[kernel_key] = next_hashes
    cell_cache[bufnr] = buf_cache
end

local function clear_cell_cache(bufnr)
    cell_cache[bufnr] = nil
end

return {
    {
        "goerz/jupytext.nvim",
        version = "0.2.0",
        opts = {
            jupytext = vim.fn.exepath("jupytext"),
            format = "py:percent",
            update = true,
        },
    },
    {
        "3rd/image.nvim",
        build = false,
        opts = {
            backend = "kitty",
            processor = "magick_cli",
            max_height_window_percentage = 50,
            hijack_file_patterns = { "*.png", "*.jpg", "*.jpeg", "*.gif", "*.webp" },
        },
    },
    {
        "benlubas/molten-nvim",
        version = "^1.0.0",
        build = ":UpdateRemotePlugins",
        ft = { "python", "quarto", "markdown" },
        init = function()
            vim.g.molten_image_provider = "image.nvim"
            vim.g.molten_output_win_max_height = 20
            vim.g.molten_virt_text_output = false
            vim.g.molten_output_virt_lines = true
            vim.g.molten_cover_empty_lines = false
            vim.g.molten_wrap_output = true
            vim.g.molten_auto_open_output = true
            vim.g.molten_output_win_style = "minimal"
            vim.g.molten_output_win_border = "rounded"
            vim.g.molten_auto_init_behavior = "init"
            vim.api.nvim_create_autocmd("FileType", {
                group = vim.api.nvim_create_augroup("JupyterMoltenScrolloff", { clear = true }),
                pattern = { "python", "quarto", "markdown" },
                callback = function()
                    vim.opt_local.scrolloff = 8
                end,
            })

            -- Run current cell (between # %% or ```python markers)
            vim.keymap.set("n", "<leader>;b", function()
                local line = vim.fn.line(".")
                local start_line, end_line
                
                -- Check for # %% style cells
                local pct_start = vim.fn.search("^# %%", "bnW")
                local pct_end = vim.fn.search("^# %%", "nW")
                
                -- Check for ```python style cells
                local md_start = vim.fn.search("^```python", "bnW")
                local md_end = vim.fn.search("^```$", "nW")
                
                -- Use whichever marker is closer/valid
                if md_start > pct_start and md_start < line then
                    start_line = md_start + 1
                    end_line = md_end > 0 and md_end - 1 or vim.fn.line("$")
                else
                    start_line = pct_start == 0 and 1 or pct_start + 1
                    end_line = pct_end == 0 and vim.fn.line("$") or pct_end - 1
                end
                
                vim.fn.MoltenEvaluateRange(start_line, end_line)
            end, { desc = "Jupyter: Run current block", silent = true })
            
            -- Map Esc to close molten output window
            vim.api.nvim_create_autocmd("FileType", {
                pattern = "molten_output",
                callback = function()
                    vim.keymap.set("n", "<Esc>", "<cmd>q<CR>", { buffer = true, silent = true })
                    vim.keymap.set("n", "q", "<cmd>q<CR>", { buffer = true, silent = true })
                end,
            })
        end,
        keys = {
            { "<leader>;i", ":MoltenInit<CR>", desc = "Jupyter: Select kernel" },
            { "<leader>;l", ":MoltenEvaluateLine<CR>", desc = "Jupyter: Eval line" },
            { "<leader>;r", ":MoltenReevaluateCell<CR>", desc = "Jupyter: Re-eval cell" },
            {
                "<leader>;a",
                function()
                    local function run_all()
                        run_cells_with_cache("all")
                    end
                    if require("molten.status").initialized() ~= "Molten" then
                        local kernels = vim.fn.MoltenAvailableKernels()
                        vim.ui.select(kernels, { prompt = "Select kernel:" }, function(choice)
                            if choice then
                                vim.cmd("MoltenInit " .. choice)
                                vim.defer_fn(run_all, 1000)
                            end
                        end)
                    else
                        run_all()
                    end
                end,
                desc = "Jupyter: Run all cells (cache-aware)",
            },
            {
                "<leader>;A",
                function()
                    local function run_to_cursor()
                        run_cells_with_cache("to_cursor")
                    end
                    if require("molten.status").initialized() ~= "Molten" then
                        local kernels = vim.fn.MoltenAvailableKernels()
                        vim.ui.select(kernels, { prompt = "Select kernel:" }, function(choice)
                            if choice then
                                vim.cmd("MoltenInit " .. choice)
                                vim.defer_fn(run_to_cursor, 1000)
                            end
                        end)
                    else
                        run_to_cursor()
                    end
                end,
                desc = "Jupyter: Run cells to cursor (cache-aware)",
            },
            { "<leader>;v", "<cmd>MoltenEvaluateVisual<CR>", mode = "x", desc = "Jupyter: Eval visual" },
            { "<leader>;d", ":MoltenDelete<CR>", desc = "Jupyter: Delete cell" },
            { "<leader>;o", ":MoltenShowOutput<CR>", desc = "Jupyter: Show output" },
            { "<leader>;e", ":noautocmd MoltenEnterOutput<CR>", desc = "Jupyter: Enter output window" },
            { "<leader>;h", ":MoltenHideOutput<CR>", desc = "Jupyter: Hide output" },
            { "<leader>;c", ":MoltenDelete<CR>", desc = "Jupyter: Clear cell output" },
            {
                "<leader>;n",
                function()
                    local row = vim.api.nvim_win_get_cursor(0)[1]
                    vim.api.nvim_buf_set_lines(0, row, row, false, { "# %%", "" })
                    vim.api.nvim_win_set_cursor(0, { row + 2, 0 })
                    vim.cmd("startinsert")
                end,
                desc = "Jupyter: New cell below (# %%)",
            },
            {
                "<leader>;N",
                function()
                    local row = vim.api.nvim_win_get_cursor(0)[1]
                    vim.api.nvim_buf_set_lines(0, row - 1, row - 1, false, { "# %%", "" })
                    vim.api.nvim_win_set_cursor(0, { row + 1, 0 })
                    vim.cmd("startinsert")
                end,
                desc = "Jupyter: New cell above (# %%)",
            },
            { "<leader>;k", ":MoltenInfo<CR>", desc = "Jupyter: Kernel info" },
            {
                "<leader>;x",
                function()
                    clear_cell_cache(vim.api.nvim_get_current_buf())
                    vim.cmd("MoltenDeinit")
                end,
                desc = "Jupyter: Stop kernel",
            },
            {
                "<leader>;X",
                function()
                    clear_cell_cache(vim.api.nvim_get_current_buf())
                    vim.cmd("MoltenDeinit")
                end,
                desc = "Jupyter: Stop ALL kernels",
            },
            {
                "<leader>;R",
                function()
                    pcall(vim.cmd, "MoltenDeinit")
                    clear_cell_cache(vim.api.nvim_get_current_buf())
                    vim.fn.delete(vim.fn.getcwd() .. "/.molten", "rf")
                    vim.notify("Kernels reset", vim.log.levels.INFO)
                    vim.cmd("MoltenInit")
                end,
                desc = "Jupyter: Reset (stop all, clear, init new)",
            },
            { "<leader>;f", function()
                vim.cmd("MoltenShowOutput")
                vim.cmd("noautocmd MoltenEnterOutput")
                local win = vim.api.nvim_get_current_win()
                local ui = vim.api.nvim_list_uis()[1]
                vim.api.nvim_win_set_config(win, {
                    relative = "editor",
                    width = ui.width - 4,
                    height = ui.height - 4,
                    row = 1,
                    col = 1,
                })
            end, desc = "Jupyter: Output fullscreen" },
            { "<leader>;P", function()
                vim.cmd("MoltenImagePopup")
            end, desc = "Jupyter: Image popup" },
        },
    },
}
