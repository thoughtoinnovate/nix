return {
	{
		"MeanderingProgrammer/render-markdown.nvim",
		--    dependencies = { 'nvim-treesitter/nvim-treesitter', 'echasnovski/mini.nvim' }, -- if you use the mini.nvim suite
		-- dependencies = { 'nvim-treesitter/nvim-treesitter', 'echasnovski/mini.icons' }, -- if you use standalone mini plugins
		dependencies = { "nvim-treesitter/nvim-treesitter", "nvim-tree/nvim-web-devicons" }, -- if you prefer nvim-web-devicons
		---@module 'render-markdown'
		---@type render.md.UserConfig
		opts = {},
		ft = { "markdown", "codecompanion" },
	},
	{
		"iamcco/markdown-preview.nvim",
		cmd = { "MarkdownPreviewToggle", "MarkdownPreview", "MarkdownPreviewStop" },
		ft = { "markdown", "html" },
		-- Avoid running an unpinned package-manager install during startup.
		build = false,
		init = function()
			vim.g.mkdp_filetypes = { "markdown", "html" }
		end,
	},
	--     {
	--         "OXY2DEV/markview.nvim",
	--         lazy = false,
	--         opts = {
	--             preview = {
	--                 filetypes = { "markdown", "codecompanion" },
	--                 ignore_buftypes = {},
	--             },
	--         },
	--     },
	--
}
