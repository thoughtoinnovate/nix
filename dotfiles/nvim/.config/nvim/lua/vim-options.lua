-- Set leader key BEFORE any mappings using it
vim.g.mapleader = ' '
vim.g.maplocalleader = ' '

-- General settings
-- vim.opt.clipboard = "unnamedplus" -- yanks to the system clipboard
vim.opt.termguicolors = true
vim.opt.cmdheight = 1
vim.opt.shortmess:append({ c = true })

-- UI settings
vim.opt.signcolumn = 'yes'
vim.opt.number = true
vim.opt.relativenumber = true
vim.opt.scrolloff = 8
vim.opt.cursorline = true

-- Search settings
vim.opt.hlsearch = true
vim.opt.incsearch = true
vim.opt.ignorecase = true
vim.opt.smartcase = true

-- Split settings
vim.opt.splitright = true
vim.opt.splitbelow = true

-- Indentation settings
vim.opt.expandtab = true
vim.opt.shiftwidth = 4
vim.opt.tabstop = 4
vim.opt.softtabstop = 4

-- File management
vim.opt.swapfile = false           -- Disable swap files (can be annoying)
vim.opt.backup = false              -- Disable backup files
vim.opt.undofile = true             -- Enable persistent undo
vim.opt.undodir = vim.fn.stdpath("data") .. "/undo"  -- Set undo directory

-- LSP & completion settings
vim.opt.updatetime = 250            -- Faster completion and diagnostics (default 4000ms)
vim.opt.timeoutlen = 500            -- Key sequence timeout (default 1000ms)

-- Better completion experience
vim.opt.completeopt = { 'menu', 'menuone', 'noselect' }
