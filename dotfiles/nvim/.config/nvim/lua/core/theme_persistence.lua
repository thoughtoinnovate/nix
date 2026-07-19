-- Theme persistence module
local M = {}

-- Path to store the current theme
local theme_file = vim.fn.stdpath("data") .. "/current_theme.txt"

-- Save the current theme to file
function M.save_theme(theme_name)
    local file = io.open(theme_file, "w")
    if file then
        file:write(theme_name)
        file:close()
        vim.notify("Theme saved: " .. theme_name, vim.log.levels.INFO, {
            title = "Theme Manager",
            timeout = 2000,
        })
    else
        vim.notify("Failed to save theme", vim.log.levels.ERROR, {
            title = "Theme Manager",
        })
    end
end

-- Load the saved theme
function M.load_theme()
    local file = io.open(theme_file, "r")
    if file then
        local theme_name = file:read("*all"):gsub("%s+", "") -- Remove whitespace
        file:close()
        if theme_name and theme_name ~= "" then
            -- Try to apply the theme
            local ok, _ = pcall(vim.cmd.colorscheme, theme_name)
            if ok then
                vim.notify("Loaded saved theme: " .. theme_name, vim.log.levels.INFO, {
                    title = "Theme Manager",
                    timeout = 1500,
                })
                return theme_name
            else
                vim.notify("Failed to load saved theme: " .. theme_name, vim.log.levels.WARN, {
                    title = "Theme Manager",
                })
            end
        end
    end
    return nil
end

-- Get the current theme name
function M.get_current_theme()
    return vim.g.colors_name or "default"
end

-- Apply theme with notification
function M.apply_theme(theme_name)
    -- Ensure theme_name is a valid string
    if type(theme_name) ~= "string" or theme_name == "" then
        vim.notify("Invalid theme name: " .. vim.inspect(theme_name), vim.log.levels.ERROR, {
            title = "Theme Manager",
        })
        return false
    end
    
    -- Clean theme name (remove any path or session info)
    theme_name = theme_name:gsub("^.*/", ""):gsub("|.*$", ""):gsub("%s+", "")
    
    local ok, _ = pcall(vim.cmd.colorscheme, theme_name)
    if ok then
        vim.notify("Applied theme: " .. theme_name, vim.log.levels.INFO, {
            title = "Theme Manager",
            timeout = 2000,
        })
        return true
    else
        vim.notify("Failed to apply theme: " .. theme_name, vim.log.levels.ERROR, {
            title = "Theme Manager",
        })
        return false
    end
end

-- Theme selector with persistence using Snacks picker
function M.theme_selector()
    local ok, Snacks = pcall(require, "snacks")
    if not ok then
        vim.notify("Snacks not available", vim.log.levels.ERROR, {
            title = "Theme Manager",
        })
        return
    end
    
    -- Use Snacks picker for colorschemes with custom confirm handler
    Snacks.picker.colorschemes({
        confirm = function(picker, item)
            picker:close()
            if item and item.text then
                local theme_name = item.text
                
                -- Clear the preview state
                if picker.preview and picker.preview.state then
                    picker.preview.state.colorscheme = nil
                end
                
                -- Apply the theme in a scheduled callback
                vim.schedule(function()
                    -- Validate it's actually a colorscheme
                    if type(theme_name) == "string" and theme_name ~= "" then
                        -- Apply the theme with notification
                        if M.apply_theme(theme_name) then
                            -- Save it for persistence
                            M.save_theme(theme_name)
                        end
                    else
                        vim.notify("Invalid theme selection", vim.log.levels.ERROR, {
                            title = "Theme Manager",
                        })
                    end
                end)
            end
        end
    })
end

-- Create user command for theme selector
vim.api.nvim_create_user_command('Themes', function()
    M.theme_selector()
end, { desc = "Open theme selector with preview and persistence" })

return M
