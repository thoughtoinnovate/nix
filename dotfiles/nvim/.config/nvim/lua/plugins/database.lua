return {
  "tpope/vim-dadbod",
  {
    "kristijanhusak/vim-dadbod-completion",
    dependencies = {
      "hrsh7th/nvim-cmp",
      "hrsh7th/cmp-buffer",
    },
    ft = { "sql", "mysql", "plsql" },
    config = function()
      local cmp = require("cmp")
      
      -- Setup nvim-cmp for SQL files only
      cmp.setup.filetype({ "sql", "mysql", "plsql" }, {
        sources = {
          { name = "vim-dadbod-completion" },
          { name = "buffer" },
        },
        mapping = cmp.mapping.preset.insert({
          ['<Tab>'] = cmp.mapping.select_next_item(),
          ['<S-Tab>'] = cmp.mapping.select_prev_item(),
          ['<CR>'] = cmp.mapping.confirm({ select = true }),
          ['<C-Space>'] = cmp.mapping.complete(),
        }),
      })
    end,
  },
  {
    "kristijanhusak/vim-dadbod-ui",
    config = function()
      vim.g.db_ui_use_nerd_fonts = 1
      vim.g.db_ui_show_database_icon = 1
      vim.g.db_ui_force_echo_messages = 1
      vim.g.db_ui_win_position = 'left'
      vim.g.db_ui_winwidth = 30
      
      -- Show database name when entering SQL buffer
      vim.api.nvim_create_autocmd("BufEnter", {
        pattern = "*.sql",
        callback = function()
          if vim.b.db then
            local db_name = vim.fn.fnamemodify(vim.b.db, ":t:r")
            vim.notify("Connected to database: " .. db_name, vim.log.levels.INFO)
          end
        end,
      })
    end,
  },
}
