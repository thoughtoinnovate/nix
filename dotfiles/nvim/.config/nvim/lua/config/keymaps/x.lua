-- ============================================================================
-- Execute/Run Code Keybindings (Namespace: <leader>x)
-- ============================================================================

local keymap = vim.keymap.set

-- Execute Lua
keymap("n", "<leader><leader>", ":%source<CR>", { desc = "Execute: Source Current Buffer" })
keymap("n", "<leader>xs", ":%source<CR>", { desc = "Execute: Source Current File" })
keymap("n", "<leader>xl", ":.lua<CR>", { desc = "Execute: Run Current Line as Lua" })
keymap("v", "<leader>xv", ":lua<CR>", { desc = "Execute: Run Visual Selection as Lua" })
keymap("n", "<leader>xf", function()
	local file = vim.fn.expand("%:p")
	vim.cmd("luafile " .. file)
end, { desc = "Execute: Run File as Lua" })

-- Execute Shell Command
keymap("n", "<leader>xx", function()
	vim.ui.input({ prompt = "Shell command: " }, function(cmd)
		if cmd and cmd ~= "" then
			vim.cmd("!" .. cmd)
		end
	end)
end, { desc = "Execute: Run Shell Command" })

-- Execute Current File (based on filetype)
keymap("n", "<leader>xr", function()
	local filetype = vim.bo.filetype
	local file = vim.fn.expand("%:p")

	local runners = {
		python = "python3 " .. file,
		javascript = "node " .. file,
		typescript = "ts-node " .. file,
		lua = "lua " .. file,
		sh = "bash " .. file,
		go = "go run " .. file,
		rust = "cargo run",
		java = "javac " .. file .. " && java " .. vim.fn.expand("%:t:r"),
	}

	local cmd = runners[filetype]
	if cmd then
		vim.cmd("!" .. cmd)
	else
		print("No runner configured for filetype: " .. filetype)
	end
end, { desc = "Execute: Run Current File" })

-- Make current file executable
keymap("n", "<leader>xc", function()
	local file = vim.fn.expand("%:p")
	vim.cmd("!chmod +x " .. file)
	print("Made executable: " .. file)
end, { desc = "Execute: Make File Executable" })
