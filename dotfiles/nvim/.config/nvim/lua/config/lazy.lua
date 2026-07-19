-- Bootstrap lazy.nvim
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not (vim.uv or vim.loop).fs_stat(lazypath) then
	local lazyrepo = "https://github.com/folke/lazy.nvim.git"
	local lazy_commit = "306a05526ada86a7b30af95c5cc81ffba93fef97"
	local out = vim.fn.system({ "git", "clone", "--filter=blob:none", lazyrepo, lazypath })
	if vim.v.shell_error == 0 then
		out = out .. vim.fn.system({ "git", "-C", lazypath, "checkout", "--detach", lazy_commit })
	end
	if vim.v.shell_error ~= 0 then
		vim.api.nvim_echo({
			{ "Failed to clone lazy.nvim:\n", "ErrorMsg" },
			{ out, "WarningMsg" },
			{ "\nPress any key to exit..." },
		}, true, {})
		vim.fn.getchar()
		os.exit(1)
	end
end
vim.opt.rtp:prepend(lazypath)

-- Setup lazy.nvim
require("lazy").setup({
	spec = {
		-- import your plugins
		{ import = "plugins" },
		{ import = "themes" },
	},
	-- Configure any other settings here. See the documentation for more details.
	-- colorscheme that will be used when installing plugins.
	install = { colorscheme = { "catpuccin" } },
	-- automatically check for plugin updates
	checker = { enabled = false },
})
