-- Automatically load all keymap modules from this directory

local keymaps_dir = vim.fn.stdpath("config") .. "/lua/config/keymaps"
local files = vim.fn.glob(keymaps_dir .. "/*.lua", false, true)

for _, file in ipairs(files) do
    local filename = vim.fn.fnamemodify(file, ":t:r")
    -- Skip init.lua and lsp.lua (lsp is loaded via lsp_common.lua)
    if filename ~= "init" and filename ~= "lsp" then
        require("config.keymaps." .. filename)
    end
end

-- Load keymap conflict checker
local ok, checker = pcall(require, "core.keymap_checker")
if ok then
    vim.defer_fn(function()
        checker.check_conflicts()
    end, 1000)
end

-- Note: LSP keymaps are loaded via lsp_common.lua on LspAttach
