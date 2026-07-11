return {
  'stevearc/oil.nvim',
  ---@module 'oil'
  ---@type oil.SetupOpts
  opts = {
    -- Oil will take over directory buffers (e.g. `vim .` or `:e src/`)
    default_file_explorer = true,
    -- Columns to show in oil buffer
    columns = {
      "icon",
    },
    -- Send deleted files to the trash instead of permanently deleting them
    delete_to_trash = true,
    -- Window-local options to use for oil buffers
    win_options = {
      signcolumn = "yes:2",
    },
    view_options = {
      -- Show files and directories that start with "."
      show_hidden = false,
      -- Sort file names in a more intuitive order for humans
      natural_order = true,
    },
  },
  dependencies = {
    "nvim-tree/nvim-web-devicons",
  },
  lazy = false,
  config = function(_, opts)
    -- Setup Oil first
    require("oil").setup(opts)

    -- Then setup oil-git-status with minimal config
    vim.schedule(function()
      require("oil-git-status").setup()
    end)
  end,
}
