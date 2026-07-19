-- Custom picker utilities for snacks.nvim

local M = {}

-- Custom vim options picker using vim.ui.select (overridden by snacks)
function M.vim_options()
    local opts_info = vim.api.nvim_get_all_options_info()
    
    -- Build list of options with their values
    local items = {}
    local display_items = {}
    
    for name, info in pairs(opts_info) do
        local ok, value = pcall(vim.api.nvim_get_option_value, name, {})
        if ok and value ~= nil then
            local value_str
            if type(value) == "table" then
                value_str = vim.inspect(value):gsub("\n", " "):gsub("%s+", " ")
            elseif type(value) == "string" then
                value_str = value == "" and '""' or value
            elseif type(value) == "boolean" then
                value_str = tostring(value)
            else
                value_str = tostring(value)
            end
            
            if #value_str > 80 then
                value_str = value_str:sub(1, 77) .. "..."
            end
            
            table.insert(items, {
                name = name,
                value = value,
                display = string.format("%-30s = %s", name, value_str),
            })
        end
    end
    
    -- Sort items alphabetically by option name
    table.sort(items, function(a, b)
        return a.name < b.name
    end)
    
    -- Build display list for picker
    for _, item in ipairs(items) do
        table.insert(display_items, item.display)
    end
    
    -- Use vim.ui.select which gets overridden by snacks to provide fuzzy finding
    vim.ui.select(display_items, {
        prompt = "Vim Options:",
        format_item = function(item)
            return item
        end,
    }, function(choice, idx)
        if choice and idx then
            local option_name = items[idx].name
            vim.cmd("help '" .. option_name .. "'")
        end
    end)
end

return M
