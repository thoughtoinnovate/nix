-- Standardized notification helper
-- Provides consistent notification formatting across the config

local M = {}

-- Default notification options
local default_opts = {
    timeout = 3000,
    animate = true,
}

-- Notification levels for easy access
M.levels = vim.log.levels

-- Info notification (default)
function M.info(message, opts)
    opts = vim.tbl_extend("force", default_opts, opts or {})
    opts.title = opts.title or "Info"
    vim.notify(message, vim.log.levels.INFO, opts)
end

-- Warning notification
function M.warn(message, opts)
    opts = vim.tbl_extend("force", default_opts, opts or {})
    opts.title = opts.title or "Warning"
    vim.notify(message, vim.log.levels.WARN, opts)
end

-- Error notification (longer timeout)
function M.error(message, opts)
    opts = vim.tbl_extend("force", default_opts, { timeout = 5000 }, opts or {})
    opts.title = opts.title or "Error"
    vim.notify(message, vim.log.levels.ERROR, opts)
end

-- Success notification (custom level using INFO)
function M.success(message, opts)
    opts = vim.tbl_extend("force", default_opts, opts or {})
    opts.title = opts.title or "Success"
    vim.notify("✓ " .. message, vim.log.levels.INFO, opts)
end

-- LSP-specific notifications
function M.lsp(message, level, opts)
    level = level or vim.log.levels.INFO
    opts = vim.tbl_extend("force", default_opts, opts or {})
    opts.title = opts.title or "LSP"
    vim.notify(message, level, opts)
end

-- Plugin-specific notifications
function M.plugin(plugin_name, message, level, opts)
    level = level or vim.log.levels.INFO
    opts = vim.tbl_extend("force", default_opts, opts or {})
    opts.title = plugin_name
    vim.notify(message, level, opts)
end

-- Quick notification for missing dependencies
function M.missing_dependency(dep_name, feature)
    local message = string.format(
        "%s not available%s",
        dep_name,
        feature and (" - " .. feature .. " disabled") or ""
    )
    M.warn(message, { title = "Missing Dependency" })
end

-- Quick notification for feature not configured
function M.not_configured(feature, filetype)
    local message = filetype
        and string.format("%s not configured for %s", feature, filetype)
        or string.format("%s not configured", feature)
    M.warn(message, { title = "Configuration" })
end

return M
