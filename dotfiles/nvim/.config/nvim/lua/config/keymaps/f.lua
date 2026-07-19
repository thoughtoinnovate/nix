-- ============================================================================
-- Find/Search Operations Keybindings (Namespace: <leader>f)
-- ============================================================================

local keymap = vim.keymap.set

-- Core Pickers
keymap("n", "<leader>ff", function()
	require("snacks").picker.smart()
end, { desc = "Find: Smart Files" })
keymap("n", "<leader>fb", function()
	require("snacks").picker.buffers()
end, { desc = "Find: Buffers" })
keymap("n", "<leader>fg", function()
	require("snacks").picker.git_files()
end, { desc = "Find: Git Files" })
keymap("n", "<leader>fr", function()
	require("snacks").picker.recent()
end, { desc = "Find: Recent Files" })
keymap("n", "<leader>fp", function()
	require("snacks").picker.projects()
end, { desc = "Find: Projects" })

-- Search/Grep
keymap("n", "<leader>f/", function()
	require("snacks").picker.grep()
end, { desc = "Find: Grep" })
keymap("n", "<leader>fw", function()
	require("snacks").picker.grep_word()
end, { desc = "Find: Word Under Cursor" })
keymap("v", "<leader>fw", function()
	require("snacks").picker.grep_word()
end, { desc = "Find: Visual Selection" })
keymap("n", "<leader>fB", function()
	require("snacks").picker.grep_buffers()
end, { desc = "Find: Grep Open Buffers" })

-- Configuration & Help
keymap("n", "<leader>fc", function()
	require("snacks").picker.files({ cwd = vim.fn.stdpath("config") })
end, { desc = "Find: Config Files" })
keymap("n", "<leader>fh", function()
	require("snacks").picker.help()
end, { desc = "Find: Help Pages" })
keymap("n", "<leader>fm", function()
	require("snacks").picker.man()
end, { desc = "Find: Man Pages" })

-- Vim Internals
keymap("n", "<leader>fk", function()
	require("snacks").picker.keymaps()
end, { desc = "Find: Keymaps" })

keymap("n", "<leader>fK", function()
	require("snacks").picker.keymaps({
		preview = false, -- Disable preview
		layout = {
			width = 0.9,
			height = 0.9,
		},
	})
end, { desc = "Find: Keymaps (No Preview)" })
keymap("n", "<leader>fC", function()
	require("snacks").picker.commands()
end, { desc = "Find: Commands" })
keymap("n", "<leader>fo", function()
	require("core.picker_utils").vim_options()
end, { desc = "Find: Vim Options" })
keymap("n", "<leader>fH", function()
	require("snacks").picker.highlights()
end, { desc = "Find: Highlights" })
keymap("n", "<leader>fa", function()
	require("snacks").picker.autocmds()
end, { desc = "Find: Autocmds" })
keymap("n", "<leader>fi", function()
	require("snacks").picker.icons()
end, { desc = "Find: Icons" })

-- History & Navigation
keymap("n", "<leader>f:", function()
	require("snacks").picker.command_history()
end, { desc = "Find: Command History" })
keymap("n", "<leader>fs", function()
	require("snacks").picker.search_history()
end, { desc = "Find: Search History" })
keymap("n", "<leader>fj", function()
	require("snacks").picker.jumps()
end, { desc = "Find: Jumps" })
keymap("n", "<leader>fM", function()
	require("snacks").picker.marks()
end, { desc = "Find: Marks" })
keymap("n", "<leader>fR", function()
	require("snacks").picker.registers()
end, { desc = "Find: Registers" })

-- Buffer Content
keymap("n", "<leader>fl", function()
	require("snacks").picker.lines()
end, { desc = "Find: Buffer Lines" })

-- Lists
keymap("n", "<leader>fq", function()
	require("snacks").picker.qflist()
end, { desc = "Find: Quickfix List" })
keymap("n", "<leader>fL", function()
	require("snacks").picker.loclist()
end, { desc = "Find: Location List" })

-- Notifications & Undo
keymap("n", "<leader>fn", function()
	require("snacks").picker.notifications()
end, { desc = "Find: Notifications" })
keymap("n", "<leader>fu", function()
	require("snacks").picker.undo()
end, { desc = "Find: Undo History" })

-- Resume Last Picker
keymap("n", "<leader>fP", function()
	require("snacks").picker.resume()
end, { desc = "Find: Resume Last Picker" })
