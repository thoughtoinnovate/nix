-- gopls LSP configuration
-- Official Go Language Server

return {
    cmd = { 'gopls' },
    filetypes = { 'go', 'gomod', 'gowork', 'gotmpl' },
    root_markers = { 'go.work', 'go.mod', '.git' },
    single_file_support = true,
    settings = {
        gopls = {
            -- Experimental features
            experimentalPostfixCompletions = true,
            experimentalUseInvalidMetadata = true,
            experimentalWatchedFileDelay = "100ms",
            
            -- Code analysis
            analyses = {
                unusedparams = true,
                unreachable = true,
                fillstruct = true,
                nonewvars = true,
                undeclaredname = true,
                unusedwrite = true,
            },
            
            -- Static check analyzers
            staticcheck = true,
            
            -- Inlay hints
            hints = {
                assignVariableTypes = true,
                compositeLiteralFields = true,
                compositeLiteralTypes = true,
                constantValues = true,
                functionTypeParameters = true,
                parameterNames = true,
                rangeVariableTypes = true,
            },
            
            -- Code completion
            completeUnimported = true,
            usePlaceholders = true,
            deepCompletion = true,
            
            -- Import organization
            gofumpt = true, -- Use gofumpt instead of gofmt
            
            -- Codelenses
            codelenses = {
                gc_details = false,
                generate = true,
                regenerate_cgo = true,
                run_govulncheck = true,
                test = true,
                tidy = true,
                upgrade_dependency = true,
                vendor = true,
            },
            
            -- Diagnostics
            diagnosticsDelay = "250ms",
            symbolMatcher = "fuzzy",
            symbolStyle = "dynamic",
            
            -- Build flags
            buildFlags = { "-tags", "integration" },
            
            -- Environment
            env = {
                GOFLAGS = "-tags=integration",
            },
            
            -- Semantic tokens
            semanticTokens = true,
        },
    },
}
