-- Database connections loader
-- Loads database connections from ~/.connections/db/connections.toml
-- See connections.toml.example in the root of this config for sample format

-- Simple TOML parser for database connections
local function parse_toml_databases(content)
    local dbs = {}
    local in_databases = false
    
    for line in content:gmatch("[^\r\n]+") do
        line = line:match("^%s*(.-)%s*$") -- trim whitespace
        
        -- Skip comments and empty lines
        if line:match("^#") or line == "" then
            goto continue
        end
        
        if line == "[databases]" then
            in_databases = true
        elseif line:match("^%[") then
            in_databases = false
        elseif in_databases and line:match("=") then
            local key, value = line:match("^([^=]+)%s*=%s*(.+)$")
            if key and value then
                key = key:match("^%s*(.-)%s*$") -- trim key
                value = value:match('^"(.-)"$') or value:match("^'(.-)'$") or value -- remove quotes
                dbs[key] = value
            end
        end
        
        ::continue::
    end
    
    return dbs
end

-- Load database connections from TOML
local function load_connections()
    local db_file = vim.fn.expand("~/.connections/db/connections.toml")
    if vim.fn.filereadable(db_file) == 1 then
        local content = table.concat(vim.fn.readfile(db_file), "\n")
        vim.g.dbs = parse_toml_databases(content)
    end
end

return {
    load_connections = load_connections
}
