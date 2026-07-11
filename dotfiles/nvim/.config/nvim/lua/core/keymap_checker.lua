-- Keymap Conflict Detection Utility
-- Checks for duplicate keybindings across all modes and provides warnings

local M = {}

-- Store all registered keymaps for conflict detection
local registered_keymaps = {}

-- Check for existing keymaps that might conflict
function M.check_conflicts()
    local modes = { "n", "v", "i", "t", "x", "o", "s", "c" }
    local conflicts = {}
    
    for _, mode in ipairs(modes) do
        local keymaps = vim.api.nvim_get_keymap(mode)
        
        for _, keymap in ipairs(keymaps) do
            local lhs = keymap.lhs
            local key = mode .. ":" .. lhs
            
            if registered_keymaps[key] then
                table.insert(conflicts, {
                    mode = mode,
                    key = lhs,
                    existing = registered_keymaps[key],
                    new = keymap.rhs or keymap.callback,
                })
            end
        end
    end
    
    if #conflicts > 0 then
        local msg = "Keymap conflicts detected:\n"
        for _, conflict in ipairs(conflicts) do
            msg = msg .. string.format("  [%s] %s\n", conflict.mode, conflict.key)
        end
        vim.notify(msg, vim.log.levels.WARN, { title = "Keymap Conflicts" })
    end
    
    return conflicts
end

-- Register a keymap for tracking
function M.register(mode, lhs, rhs, opts)
    local modes = type(mode) == "table" and mode or { mode }
    
    for _, m in ipairs(modes) do
        local key = m .. ":" .. lhs
        registered_keymaps[key] = {
            rhs = rhs,
            desc = opts and opts.desc or "No description",
            file = debug.getinfo(2, "S").source:match("^@?(.*)$"),
        }
    end
    
    vim.keymap.set(mode, lhs, rhs, opts)
end

-- List all keymaps by namespace
function M.list_by_namespace()
    local namespaces = {}
    
    for key, info in pairs(registered_keymaps) do
        local mode, lhs = key:match("^(.):(.+)$")
        local namespace = lhs:match("^<leader>(%a)") or "other"
        
        if not namespaces[namespace] then
            namespaces[namespace] = {}
        end
        
        table.insert(namespaces[namespace], {
            mode = mode,
            key = lhs,
            desc = info.desc,
            file = info.file,
        })
    end
    
    return namespaces
end

return M
