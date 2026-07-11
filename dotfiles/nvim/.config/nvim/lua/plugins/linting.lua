return {
  "mfussenegger/nvim-lint",
  event = { "BufReadPre", "BufNewFile" },
  config = function()
    local lint = require("lint")

    lint.linters_by_ft = {
      python = { "ruff" },
      javascript = { "eslint_d" },
      typescript = { "eslint_d" },
      javascriptreact = { "eslint_d" },
      typescriptreact = { "eslint_d" },
      go = { "golangcilint" },
      bash = { "shellcheck" },
      sh = { "shellcheck" },
      lua = { "luacheck" },
      html = { "htmlhint" },
      css = { "stylelint" },
      scss = { "stylelint" },
      java = { "checkstyle" },
      json = { "jsonlint" },
      yaml = { "yamllint" },
      sql = { "sqlfluff" },
      markdown = { "markdownlint" },
    }

    -- Initialize linting state
    if vim.g.linting_enabled == nil then
      vim.g.linting_enabled = true
    end

    local lint_augroup = vim.api.nvim_create_augroup("lint", { clear = true })

    vim.api.nvim_create_autocmd({ "BufEnter", "BufWritePost", "InsertLeave" }, {
      group = lint_augroup,
      callback = function()
        -- Only run linting if enabled
        if vim.g.linting_enabled then
          lint.try_lint()
        end
      end,
    })
  end,
}
