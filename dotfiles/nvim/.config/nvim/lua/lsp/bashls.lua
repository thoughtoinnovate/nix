-- bash-language-server LSP configuration
-- Official Bash Language Server

return {
    cmd = { 'bash-language-server', 'start' },
    filetypes = { 'sh', 'bash', 'zsh' },
    root_markers = { '.git' },
    single_file_support = true,
    settings = {
        bashIde = {
            -- Enable/disable background analysis
            backgroundAnalysisMaxFiles = 500,
            
            -- Enable/disable shellcheck integration
            enableSourceErrorDiagnostics = false,
            
            -- Shellcheck configuration
            shellcheckPath = "shellcheck",
            shellcheckArguments = {
                "--external-sources",
                "--format=json",
                "--shell=bash",
                "--enable=all",
            },
            
            -- Glob patterns for files to include/exclude
            includeAllWorkspaceSymbols = true,
            
            -- Explainshell endpoint for hover documentation
            explainshellEndpoint = "https://explainshell.com/explain",
        },
    },
}
