-- ============================================================================
-- LSP Go-to Navigation Keybindings (Namespace: g, no leader)
-- ============================================================================
-- These are set globally but will only work when an LSP is attached

local keymap = vim.keymap.set

-- LSP Navigation (Go-to operations)
keymap("n", "gd", vim.lsp.buf.definition, { desc = "Go-to: Definition" })
keymap("n", "gD", vim.lsp.buf.declaration, { desc = "Go-to: Declaration" })
keymap("n", "gi", vim.lsp.buf.implementation, { desc = "Go-to: Implementation" })
keymap("n", "gr", vim.lsp.buf.references, { desc = "Go-to: References" })
keymap("n", "gt", vim.lsp.buf.type_definition, { desc = "Go-to: Type Definition" })

-- Hover & Signature Help
keymap("n", "K", vim.lsp.buf.hover, { desc = "Go-to: Hover Documentation" })
keymap({ "n", "i" }, "<C-k>", vim.lsp.buf.signature_help, { desc = "Go-to: Signature Help" })

-- Diagnostic Navigation
keymap("n", "[d", vim.diagnostic.goto_prev, { desc = "Go-to: Previous Diagnostic" })
keymap("n", "]d", vim.diagnostic.goto_next, { desc = "Go-to: Next Diagnostic" })
keymap("n", "gl", vim.diagnostic.open_float, { desc = "Go-to: Line Diagnostics" })

-- Word Reference Navigation (Snacks)
keymap({ "n", "t" }, "]]", function()
	require("snacks").words.jump(1)
end, { desc = "Go-to: Next Reference" })
keymap({ "n", "t" }, "[[", function()
	require("snacks").words.jump(-1)
end, { desc = "Go-to: Previous Reference" })
