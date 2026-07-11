return {
  -- Conform.nvim for formatting
  {
    "stevearc/conform.nvim",
    event = { "BufWritePre" },
    cmd = { "ConformInfo" },
    keys = {
      {
        "<leader>=",
        function()
          require("conform").format({ async = true })
        end,
        mode = "",
        desc = "Format buffer",
      },
    },
    opts = {
      -- Define your formatters
      formatters_by_ft = {
        -- Rust formatting with rustfmt (official Rust formatter)
        rust = { "rustfmt" },
        
        -- Java formatting with Google Java Format
        java = { "google-java-format" },
        
        -- Go formatting with goimports (includes gofmt + import management)
        go = { "golines", "goimports" },
        
        -- Bash/Shell formatting with shfmt
        bash = { "shfmt" },
        sh = { "shfmt" },
        zsh = { "shfmt" },
        
        -- Add other languages as needed
        lua = { "stylua" },
        python = { "black" },
        javascript = { "prettier" },
        typescript = { "prettier" },
        javascriptreact = { "prettier" },
        typescriptreact = { "prettier" },
        html = { "prettier" },
        css = { "prettier" },
        scss = { "prettier" },
        json = { "prettier" },
        yaml = { "prettier" },
        markdown = { "prettier" },
        dockerfile = { "prettier" },
        toml = { "taplo" },
        xml = { "xmlformat" },
        sql = { "sqlfluff" },
      },
      
      -- Set default options
      default_format_opts = {
        lsp_format = "fallback",
      },
      
      -- Format on save configuration
      format_on_save = function(bufnr)
        -- Disable with a global or buffer-local variable
        if vim.g.disable_autoformat or vim.b[bufnr].disable_autoformat then
          return
        end
        
        return {
          timeout_ms = 300,
          lsp_format = "fallback",
        }
      end,
      
      -- Custom formatters configuration
      formatters = {
        rustfmt = {
          -- Use rustfmt from rustup
          command = "rustfmt",
          args = { "--edition", "2021" },
          stdin = true,
        },
        ["google-java-format"] = {
          -- Google Java Format
          command = "google-java-format",
          args = { "-" },
          stdin = true,
        },
        goimports = {
          -- Go imports formatter (includes gofmt)
          command = "goimports",
          stdin = true,
        },
        golines = {
          -- Go formatter with line length control
          command = "golines",
          args = { "--max-len=120", "--base-formatter=gofumpt" },
          stdin = true,
        },
        gofmt = {
          -- Go formatter
          command = "gofmt",
          stdin = true,
        },
        shfmt = {
          -- Shell formatter
          command = "shfmt",
          args = { "-i", "2", "-ci" }, -- 2 spaces indent, switch cases indent
          stdin = true,
        },
      },
    },
    config = function(_, opts)
      require("conform").setup(opts)
      
      -- Create commands to toggle format on save
      vim.api.nvim_create_user_command("FormatDisable", function(args)
        if args.bang then
          -- FormatDisable! will disable formatting just for this buffer
          vim.b.disable_autoformat = true
        else
          vim.g.disable_autoformat = true
        end
      end, {
        desc = "Disable autoformat-on-save",
        bang = true,
      })
      
      vim.api.nvim_create_user_command("FormatEnable", function()
        vim.b.disable_autoformat = false
        vim.g.disable_autoformat = false
      end, {
        desc = "Re-enable autoformat-on-save",
      })
      
      -- Language-specific format commands
      vim.api.nvim_create_user_command("FormatJava", function()
        require("conform").format({ formatters = { "google-java-format" } })
      end, { desc = "Format Java with Google Java Format" })
      
      vim.api.nvim_create_user_command("FormatGo", function()
        require("conform").format({ formatters = { "goimports" } })
      end, { desc = "Format Go with goimports" })
      
      vim.api.nvim_create_user_command("FormatRust", function()
        require("conform").format({ formatters = { "rustfmt" } })
      end, { desc = "Format Rust with rustfmt" })
      
      vim.api.nvim_create_user_command("FormatShell", function()
        require("conform").format({ formatters = { "shfmt" } })
      end, { desc = "Format Shell with shfmt" })
    end,
  },
}
