return {
	"nvim-lualine/lualine.nvim",
	config = function()
		local trouble = require("trouble")
		local symbols = trouble.statusline({
			mode = "lsp_document_symbols",
			groups = {},
			title = false,
			filter = { range = true },
			format = "{kind_icon}{symbol.name:Normal}",
			-- The following line is needed to fix the background color
			-- Set it to the lualine section you want to use
			hl_group = "lualine_c_normal",
		})
		require("lualine").setup({
			options = {
				theme = "everforest",
			},
			sections = {
				lualine_c = {
					symbols.get,
					symbols.has,
					{
						function()
							return " "
						end,
						color = function()
							local status = require("sidekick.status").get()
							if status then
								return status.kind == "Error" and "DiagnosticError"
									or status.busy and "DiagnosticWarn"
									or "Special"
							end
						end,
						cond = function()
							local status = require("sidekick.status")
							return status.get() ~= nil
						end,
					},
				},
				lualine_x = {
					{
						function()
							local status = require("sidekick.status").cli()
							return " " .. (#status > 1 and #status or "")
						end,
						cond = function()
							return #require("sidekick.status").cli() > 0
						end,
						color = function()
							return "Special"
						end,
					},
				},
			},
		})
	end,
}
