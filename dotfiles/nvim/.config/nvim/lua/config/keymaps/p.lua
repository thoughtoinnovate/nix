-- ============================================================================
-- Project/Workspace Keybindings (Namespace: <leader>p)
-- ============================================================================
-- Note: Project picker is in f.lua (<leader>fp)
-- Note: LSP workspace folders are in l.lua (<leader>lwa/lwr/lwl)

local keymap = vim.keymap.set

-- Project Root Operations
keymap("n", "<leader>pr", function()
	local root = vim.fn.getcwd()
	print("Project Root: " .. root)
end, { desc = "Project: Show Root" })

keymap("n", "<leader>pc", function()
	vim.ui.input({ prompt = "Change project root to: ", default = vim.fn.getcwd() }, function(input)
		if input then
			vim.cmd("cd " .. input)
			print("Changed to: " .. input)
		end
	end)
end, { desc = "Project: Change Root Directory" })

-- Additional project-related keybindings can be added here
