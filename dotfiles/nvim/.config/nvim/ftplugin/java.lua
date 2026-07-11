local home = vim.uv.os_homedir()
local mason_path = vim.fn.stdpath("data") .. "/mason"
local workspace_dir = home .. "/.cache/jdtls/workspace/" .. vim.fn.fnamemodify(vim.fn.getcwd(), ":p:h:t")
local debug_path = mason_path .. "/packages/java-debug-adapter/extension/server"
local test_path = mason_path .. "/packages/java-test/extension/server"
local jdtls_command = vim.fn.exepath("jdtls")

if jdtls_command == "" then
    vim.notify("[jdtls] Enable the Nix development profile to install jdtls", vim.log.levels.ERROR)
    return
end

-- Mason-provided debug and test adapters remain optional. The language server
-- itself always comes from the active Nix profile.
local debug_jars = vim.fn.glob(debug_path .. "/com.microsoft.java.debug.plugin-*.jar", true, true)
local test_jars = vim.fn.glob(test_path .. "/*.jar", true, true)
local bundles = {}
vim.list_extend(bundles, debug_jars)
vim.list_extend(bundles, test_jars)

-- Detect JAVA HOME
local function resolve_java_home()
    local java_home = vim.env.JAVA_HOME
    if java_home and java_home ~= "" then
        return java_home
    end

    local java_cmd = vim.fn.exepath("java")
    if java_cmd ~= "" then
        return vim.fn.fnamemodify(java_cmd, ":h:h")
    end
    return nil
end

local java_home = resolve_java_home()

if not java_home or java_home == "" then
    vim.notify("[jdtls] ❌ Could not resolve JAVA_HOME!", vim.log.levels.ERROR)
    return
end

--------------------------------------------------------------------------------
-- Client capabilities --------------------------------------------------------
--------------------------------------------------------------------------------

local capabilities = vim.lsp.protocol.make_client_capabilities()
capabilities.workspace.configuration = true
capabilities.textDocument.completion.completionItem.snippetSupport = true

-- Extra capabilities that are understood by Eclipse JDT.LS
local extended_caps = require('jdtls').extendedClientCapabilities
extended_caps.resolveAdditionalTextEditsSupport = true

--------------------------------------------------------------------------------
-- Find the project root -------------------------------------------------------
--------------------------------------------------------------------------------

local jdtls_setup = require('jdtls.setup')
local root_dir = jdtls_setup.find_root({
    'settings.gradle', 'settings.gradle.kts', 'build.gradle', 'build.gradle.kts',
    'pom.xml', 'gradlew', 'mvnw', '.git'
})

if not root_dir then
    vim.notify('[jdtls] ⚠  Could not locate project root. Language-server disabled.',
        vim.log.levels.WARN)
    return
end

--------------------------------------------------------------------------------
-- Build the final config table ----------------------------------------------
--------------------------------------------------------------------------------

local config = {
    cmd = {
        jdtls_command,
        "-data", workspace_dir,
    },

    root_dir = root_dir,

    init_options = {
        bundles = bundles,
        extendedClientCapabilities = extended_caps,
    },

    capabilities = capabilities,

    settings = {
        java = {
            autobuild = { enabled = true },
            import = {
                gradle = { enabled = true, wrapper = { enabled = true } },
                maven = { enabled = true },
            },
            configuration = {
                updateBuildConfiguration = "interactive",
                runtimes = {
                    {
                        name = "JAVA_HOME",
                        path = java_home,
                        default = true,
                    },
                },
            },
        },
    },

    on_attach = function(client, bufnr)
        local jdtls = require('jdtls')

        -- The generic LSP on_attach (key-maps, highlighting, …) is defined in
        -- lua/core/lsp_common.lua and is executed automatically.  Here we only
        -- add Java-specific niceties.

        local function map(mode, lhs, rhs, desc)
            vim.keymap.set(mode, lhs, rhs, {
                buffer = bufnr, silent = true, noremap = true, desc = desc
            })
        end

        ---------------------------------------------------------------------
        -- Generic navigation -------------------------------------------------
        ---------------------------------------------------------------------
        map('n', 'gd', vim.lsp.buf.definition,        'Go to Definition')
        map('n', 'gD', vim.lsp.buf.declaration,       'Go to Declaration')
        map('n', 'gi', vim.lsp.buf.implementation,    'Go to Implementation')
        map('n', 'gr', vim.lsp.buf.references,        'List References')
        map('n', 'K',  vim.lsp.buf.hover,             'Hover Documentation')

        ---------------------------------------------------------------------
        -- Refactor helpers ---------------------------------------------------
        ---------------------------------------------------------------------
        map('n', '<leader>oi', jdtls.organize_imports, 'Organise Imports')
        map('v', '<leader>ev', jdtls.extract_variable, 'Extract Variable')
        map('v', '<leader>ec', jdtls.extract_constant, 'Extract Constant')
        map('v', '<leader>em', jdtls.extract_method,   'Extract Method')

        ---------------------------------------------------------------------
        -- Testing / debugging -----------------------------------------------
        ---------------------------------------------------------------------
        jdtls.setup_dap({ hotcodereplace = 'auto' })
        require('jdtls.dap').setup_dap_main_class_configs()
        map('n', '<leader>jt', jdtls.test_class,          'Java: Test Class')
        map('n', '<leader>jtn', jdtls.test_nearest_method, 'Java: Test Nearest Method')

        ---------------------------------------------------------------------
        -- Code-lens auto-refresh --------------------------------------------
        ---------------------------------------------------------------------
        if client.server_capabilities.codeLensProvider then
            vim.api.nvim_create_autocmd({ 'BufEnter', 'BufWritePost', 'CursorHold' }, {
                buffer = bufnr,
                callback = function()
                    pcall(vim.lsp.codelens.refresh)
                end,
            })
        end
    end,
}
-- print(vim.inspect(bundles))
require("jdtls").start_or_attach(config)
