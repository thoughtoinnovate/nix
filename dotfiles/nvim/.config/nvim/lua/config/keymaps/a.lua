-- ============================================================================
-- AI/Copilot/Code Companions Keybindings (Namespace: <leader>a)
-- ============================================================================
-- Note: Copilot inline keybindings (<C-l>) are configured in plugins/ai.lua
-- Note: Sidekick additional keybindings (<tab>, <c-.>) are in plugins/ai.lua

local keymap = vim.keymap.set

-- Sidekick AI Assistant
keymap("n", "<leader>aa", function()
	require("sidekick.cli").toggle()
end, { desc = "AI: Sidekick Toggle CLI" })

keymap({ "n", "i" }, "<leader>al", function()
	require("sidekick").nes_jump_or_apply()
end, { desc = "AI: Apply Sidekick NSE Suggestion" })

keymap("n", "<leader>as", function()
	require("sidekick.cli").select()
end, { desc = "AI: Sidekick Select CLI" })

keymap("n", "<leader>ad", function()
	require("sidekick.cli").close()
end, { desc = "AI: Sidekick Detach Session" })

keymap({ "x", "n" }, "<leader>at", function()
	require("sidekick.cli").send({ msg = "{this}" })
end, { desc = "AI: Sidekick Send This" })

keymap("n", "<leader>af", function()
	require("sidekick.cli").send({ msg = "{file}" })
end, { desc = "AI: Sidekick Send File" })

keymap("x", "<leader>av", function()
	require("sidekick.cli").send({ msg = "{selection}" })
end, { desc = "AI: Sidekick Send Selection" })

keymap({ "n", "x" }, "<leader>ap", function()
	require("sidekick.cli").prompt()
end, { desc = "AI: Sidekick Select Prompt" })

keymap("n", "<leader>ac", function()
	require("sidekick.cli").toggle({ name = "claude", focus = true })
end, { desc = "AI: Sidekick Toggle Claude" })

-- CodeCompanion
keymap({ "n", "v" }, "<leader>aA", "<cmd>CodeCompanionActions<cr>", { desc = "AI: CodeCompanion Actions" })
keymap({ "n", "v" }, "<leader>aC", "<cmd>CodeCompanionChat Toggle<cr>", { desc = "AI: CodeCompanion Chat" })
keymap("v", "<leader>aE", "<cmd>CodeCompanionChat Add<cr>", { desc = "AI: CodeCompanion Add to Chat" })
