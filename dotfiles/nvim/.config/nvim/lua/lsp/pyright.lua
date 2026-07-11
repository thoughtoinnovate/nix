local function get_default_python()
    local python = vim.fn.exepath("python3")
    return python ~= "" and python or "python3"
end

local function get_python_path()
    local cwd = vim.fn.getcwd()
    -- Check common venv locations
    local venv_paths = {
        cwd .. "/.venv",
        cwd .. "/venv",
        cwd .. "/.env",
    }
    
    for _, venv in ipairs(venv_paths) do
        if vim.fn.isdirectory(venv) == 1 then
            local python_path = venv .. "/bin/python"
            if vim.fn.executable(python_path) == 1 then
                return python_path
            end
        end
    end
    return get_default_python()
end

return {
    cmd = { "pyright-langserver", "--stdio" },
    root_markers = { "pyproject.toml", "setup.py", ".git", "requirements.txt", "setup.cfg", "tox.ini", "manage.py" },
    filetypes = { "python" },
    settings = {
        python = {
            pythonPath = get_python_path(),
            analysis = {
                typeCheckingMode = "basic",
                useLibraryCodeForTypes = true,
                autoSearchPaths = true,
                reportMissingImports = true,
                reportUnusedVariable = "warning",
            }
        }
    }
}
