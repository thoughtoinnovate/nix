return {
  -- Go development plugin
  {
    "ray-x/go.nvim",
    dependencies = {
      "ray-x/guihua.lua",
      "nvim-treesitter/nvim-treesitter",
    },
    config = function()
      require("go").setup({
        -- Disable default keymaps (we'll set our own)
        disable_defaults = false,
        
        -- Go imports
        goimports = "goimports", -- goimports command, can be gopls
        gofmt = "golines", -- use golines for line length formatting
        
        -- Max line length for golines
        max_line_len = 120,
        
        -- Tag options
        tag_transform = false,
        tag_options = "json=omitempty",
        
        -- Test options
        gotests = {
          template = "", -- sets gotests -template parameter (check gotests for details)
          template_dir = "", -- sets gotests -template_dir parameter (check gotests for details)
        },
        
        -- Comment options
        comment_placeholder = "   ",
        
        -- Icons
        icons = { breakpoint = "🧘", currentpos = "🏃" },
        
        -- Verbose output
        verbose = false,
        
        -- Log path
        log_path = vim.fn.expand("$HOME") .. "/tmp/gonvim.log",
        
        -- LSP configuration
        lsp_cfg = false, -- We handle LSP configuration separately
        
        -- LSP inlay hints
        lsp_inlay_hints = {
          enable = true,
          -- Only show inlay hints for the current line
          only_current_line = false,
          -- Event which triggers a refresh of the inlay hints
          only_current_line_autocmd = "CursorHold",
          -- whether to show variable name before type hints with the inlay hints or not
          show_variable_name = true,
          -- prefix for parameter hints
          parameter_hints_prefix = "󰊕 ",
          show_parameter_hints = true,
          -- prefix for all the other hints (type, chaining)
          other_hints_prefix = "=> ",
          -- whether to align to the length of the longest line in the file
          max_len_align = false,
          -- padding from the left if max_len_align is true
          max_len_align_padding = 1,
          -- whether to align to the extreme right or not
          right_align = false,
          -- padding from the right if right_align is true
          right_align_padding = 6,
          -- The color of the hints
          highlight = "Comment",
        },
        
        -- Diagnostic configuration
        lsp_diag_hdlr = true,
        lsp_diag_underline = true,
        lsp_diag_virtual_text = { space = 0, prefix = "" },
        lsp_diag_signs = true,
        lsp_diag_update_in_insert = false,
        
        -- Code lens
        lsp_codelens = true,
        
        -- Formatting
        lsp_format_on_save = false, -- We handle this with conform.nvim
        
        -- Go generate
        go_generate_env = {},
        
        -- Test configuration
        test_runner = "go", -- richgo, go, richgo, dlv, ginkgo
        run_in_floaterm = false, -- set to true to run in float window.
        
        -- DAP configuration
        dap_debug = true,
        dap_debug_keymap = true,
        dap_debug_gui = true,
        dap_debug_vt = true,
        
        -- Build tags
        build_tags = "tag1,tag2",
        textobjects = true, -- enable default text objects through treesittter-text-objects
        test_efm = false, -- errorfomat for quickfix, default mix mode, set to true will be efm only
        
        -- Snippet integration (disabled - using blink.cmp's built-in snippets)
        luasnip = false,
      })
      
      -- Auto commands for Go files
      local format_sync_grp = vim.api.nvim_create_augroup("GoImport", {})
      vim.api.nvim_create_autocmd("BufWritePre", {
        pattern = "*.go",
        callback = function()
          require('go.format').goimports()
        end,
        group = format_sync_grp,
      })
      
      -- Go-specific keymaps
      vim.api.nvim_create_autocmd("FileType", {
        pattern = "go",
        callback = function()
          local opts = { noremap = true, silent = true, buffer = true }
          
          -- Go commands
          vim.keymap.set('n', '<leader>gr', '<cmd>GoRun<CR>', vim.tbl_extend('force', opts, { desc = 'Go run' }))
          vim.keymap.set('n', '<leader>gb', '<cmd>GoBuild<CR>', vim.tbl_extend('force', opts, { desc = 'Go build' }))
          vim.keymap.set('n', '<leader>gt', '<cmd>GoTest<CR>', vim.tbl_extend('force', opts, { desc = 'Go test' }))
          vim.keymap.set('n', '<leader>gT', '<cmd>GoTestFunc<CR>', vim.tbl_extend('force', opts, { desc = 'Go test function' }))
          vim.keymap.set('n', '<leader>gc', '<cmd>GoCoverage<CR>', vim.tbl_extend('force', opts, { desc = 'Go coverage' }))
          
          -- Go tools
          vim.keymap.set('n', '<leader>gi', '<cmd>GoImports<CR>', vim.tbl_extend('force', opts, { desc = 'Go imports' }))
          vim.keymap.set('n', '<leader>gf', '<cmd>GoFmt<CR>', vim.tbl_extend('force', opts, { desc = 'Go format' }))
          vim.keymap.set('n', '<leader>gl', '<cmd>GoLint<CR>', vim.tbl_extend('force', opts, { desc = 'Go lint' }))
          vim.keymap.set('n', '<leader>gv', '<cmd>GoVet<CR>', vim.tbl_extend('force', opts, { desc = 'Go vet' }))
          
          -- Go generate and mod
          vim.keymap.set('n', '<leader>gg', '<cmd>GoGenerate<CR>', vim.tbl_extend('force', opts, { desc = 'Go generate' }))
          vim.keymap.set('n', '<leader>gm', '<cmd>GoMod<CR>', vim.tbl_extend('force', opts, { desc = 'Go mod' }))
          
          -- Go debugging
          vim.keymap.set('n', '<leader>gd', '<cmd>GoDebug<CR>', vim.tbl_extend('force', opts, { desc = 'Go debug' }))
          vim.keymap.set('n', '<leader>gD', '<cmd>GoDbgStop<CR>', vim.tbl_extend('force', opts, { desc = 'Stop Go debug' }))
          
          -- Go tags
          vim.keymap.set('n', '<leader>ga', '<cmd>GoAddTag<CR>', vim.tbl_extend('force', opts, { desc = 'Add Go tags' }))
          vim.keymap.set('n', '<leader>gR', '<cmd>GoRmTag<CR>', vim.tbl_extend('force', opts, { desc = 'Remove Go tags' }))
          
          -- Go implementation and interface
          vim.keymap.set('n', '<leader>gI', '<cmd>GoImpl<CR>', vim.tbl_extend('force', opts, { desc = 'Go implement interface' }))
          vim.keymap.set('n', '<leader>gF', '<cmd>GoFillStruct<CR>', vim.tbl_extend('force', opts, { desc = 'Go fill struct' }))
        end,
      })
    end,
    event = { "CmdlineEnter" },
    ft = { "go", 'gomod' },
    -- Go binaries are supplied by the pinned Nix development profile.
    build = false,
  },
}
