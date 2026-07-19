-- ============================================================================
-- LSP Server Management Keybindings (Namespace: <leader>l)
-- ============================================================================

local keymap = vim.keymap.set

-- Workspace Folders
keymap("n", "<leader>lwa", vim.lsp.buf.add_workspace_folder, { desc = "LSP: Add Workspace Folder" })
keymap("n", "<leader>lwr", vim.lsp.buf.remove_workspace_folder, { desc = "LSP: Remove Workspace Folder" })
keymap("n", "<leader>lwl", function()
	print(vim.inspect(vim.lsp.buf.list_workspace_folders()))
end, { desc = "LSP: List Workspace Folders" })

-- Diagnostics
keymap("n", "<leader>lq", vim.diagnostic.setloclist, { desc = "LSP: Diagnostics to Location List" })
keymap("n", "<leader>lh", function()
	vim.lsp.inlay_hint.enable(not vim.lsp.inlay_hint.is_enabled())
end, { desc = "LSP: Toggle Inlay Hints" })

-- LSP Code Listings (Snacks Pickers)
keymap("n", "<leader>lcd", function()
	require("snacks").picker.lsp_definitions()
end, { desc = "LSP: List Definitions" })
keymap("n", "<leader>lcD", function()
	require("snacks").picker.lsp_declarations()
end, { desc = "LSP: List Declarations" })
keymap("n", "<leader>lcr", function()
	require("snacks").picker.lsp_references()
end, { desc = "LSP: List References" })
keymap("n", "<leader>lci", function()
	require("snacks").picker.lsp_implementations()
end, { desc = "LSP: List Implementations" })
keymap("n", "<leader>lct", function()
	require("snacks").picker.lsp_type_definitions()
end, { desc = "LSP: List Type Definitions" })
keymap("n", "<leader>lcs", function()
	require("snacks").picker.lsp_symbols()
end, { desc = "LSP: List Document Symbols" })
keymap("n", "<leader>lcS", function()
	require("snacks").picker.lsp_workspace_symbols()
end, { desc = "LSP: List Workspace Symbols" })
keymap("n", "<leader>lcI", function()
	require("snacks").picker.lsp_incoming_calls()
end, { desc = "LSP: List Incoming Calls" })
keymap("n", "<leader>lcO", function()
	require("snacks").picker.lsp_outgoing_calls()
end, { desc = "LSP: List Outgoing Calls" })

-- Diagnostics Pickers
keymap("n", "<leader>ld", function()
	require("snacks").picker.diagnostics()
end, { desc = "LSP: Diagnostics (Workspace)" })
keymap("n", "<leader>lD", function()
	require("snacks").picker.diagnostics_buffer()
end, { desc = "LSP: Diagnostics (Buffer)" })
