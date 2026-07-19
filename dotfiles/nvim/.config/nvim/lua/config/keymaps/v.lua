-- ============================================================================
-- Version Control (Git) Keybindings (Namespace: <leader>v)
-- ============================================================================

local keymap = vim.keymap.set

-- Lazygit
keymap("n", "<leader>vg", function()
	require("snacks").lazygit()
end, { desc = "Git: Lazygit" })

keymap("n", "<leader>vf", function()
	require("snacks").lazygit.log_file()
end, { desc = "Git: Lazygit File History" })

keymap("n", "<leader>vl", function()
	require("snacks").lazygit.log()
end, { desc = "Git: Lazygit Log" })

-- Git Operations (Snacks Pickers)
keymap("n", "<leader>vb", function()
	require("snacks").picker.git_branches()
end, { desc = "Git: Branches" })

keymap("n", "<leader>vc", function()
	require("snacks").picker.git_log()
end, { desc = "Git: Commits (Log)" })

keymap("n", "<leader>vC", function()
	require("snacks").picker.git_log_line()
end, { desc = "Git: Commits (Line History)" })

keymap("n", "<leader>vs", function()
	require("snacks").picker.git_status()
end, { desc = "Git: Status" })

keymap("n", "<leader>vS", function()
	require("snacks").picker.git_stash()
end, { desc = "Git: Stash" })

keymap("n", "<leader>vd", function()
	require("snacks").picker.git_diff()
end, { desc = "Git: Diff (Hunks)" })

keymap("n", "<leader>vF", function()
	require("snacks").picker.git_log_file()
end, { desc = "Git: File History" })

-- Git Blame & Browse
keymap("n", "<leader>vB", function()
	require("snacks").git.blame_line()
end, { desc = "Git: Blame Line" })

keymap({ "n", "v" }, "<leader>vo", function()
	require("snacks").gitbrowse()
end, { desc = "Git: Open in Browser" })

-- Git Pull & Fetch
keymap("n", "<leader>vpl", function()
	vim.cmd("!git pull")
end, { desc = "Git: Pull" })

keymap("n", "<leader>vpu", function()
	vim.cmd("!git push")
end, { desc = "Git: Push" })

keymap("n", "<leader>vft", function()
	vim.cmd("!git fetch")
end, { desc = "Git: Fetch" })

keymap("n", "<leader>vfa", function()
	vim.cmd("!git fetch --all")
end, { desc = "Git: Fetch All" })

-- GitHub Operations (requires gh cli)
keymap("n", "<leader>vi", function()
	require("snacks").picker.gh_issue()
end, { desc = "Git: GitHub Issues (Open)" })

keymap("n", "<leader>vI", function()
	require("snacks").picker.gh_issue({ state = "all" })
end, { desc = "Git: GitHub Issues (All)" })

keymap("n", "<leader>vp", function()
	require("snacks").picker.gh_pr()
end, { desc = "Git: GitHub PRs (Open)" })

keymap("n", "<leader>vP", function()
	require("snacks").picker.gh_pr({ state = "all" })
end, { desc = "Git: GitHub PRs (All)" })

-- Diffview
keymap("n", "<leader>vD", "<cmd>DiffviewOpen<cr>", { desc = "Git: Open Diffview" })
keymap("n", "<leader>vX", "<cmd>DiffviewClose<cr>", { desc = "Git: Close Diffview" })
keymap("n", "<leader>vh", "<cmd>DiffviewFileHistory<cr>", { desc = "Git: File History (Diffview)" })
keymap("n", "<leader>vH", "<cmd>DiffviewFileHistory %<cr>", { desc = "Git: Current File History (Diffview)" })

-- Git Clone
keymap("n", "<leader>vG", function()
	vim.ui.input({ prompt = "Git clone URL: " }, function(url)
		if url and url ~= "" then
			vim.ui.input({ prompt = "Clone to directory: ", default = vim.fn.getcwd() }, function(dir)
				if dir and dir ~= "" then
					vim.cmd("!git clone " .. url .. " " .. dir)
				end
			end)
		end
	end)
end, { desc = "Git: Clone Repository" })
