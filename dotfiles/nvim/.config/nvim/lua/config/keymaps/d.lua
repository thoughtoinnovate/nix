-- ============================================================================
-- Debug Operations Keybindings (Namespace: <leader>d)
-- ============================================================================

local keymap = vim.keymap.set

-- Breakpoints
keymap("n", "<leader>db", function()
	require("dap").toggle_breakpoint()
end, { desc = "Debug: Toggle Breakpoint" })
keymap("n", "<leader>dB", function()
	require("dap").set_breakpoint(vim.fn.input("Breakpoint condition: "))
end, { desc = "Debug: Conditional Breakpoint" })
keymap("n", "<leader>dX", function()
	require("dap").clear_breakpoints()
end, { desc = "Debug: Clear All Breakpoints" })

-- Debug Control
keymap("n", "<leader>dc", function()
	require("dap").continue()
end, { desc = "Debug: Continue/Start" })
keymap("n", "<leader>dC", function()
	require("dap").run_to_cursor()
end, { desc = "Debug: Run to Cursor" })
keymap("n", "<leader>di", function()
	require("dap").step_into()
end, { desc = "Debug: Step Into" })
keymap("n", "<leader>do", function()
	require("dap").step_over()
end, { desc = "Debug: Step Over" })
keymap("n", "<leader>dO", function()
	require("dap").step_out()
end, { desc = "Debug: Step Out" })
keymap("n", "<leader>dr", function()
	require("dap").restart()
end, { desc = "Debug: Restart" })
keymap("n", "<leader>dt", function()
	require("dap").terminate()
end, { desc = "Debug: Terminate" })

-- Debug UI
keymap("n", "<leader>du", function()
	require("dapui").toggle()
end, { desc = "Debug: Toggle UI" })
keymap({ "n", "v" }, "<leader>de", function()
	require("dapui").eval()
end, { desc = "Debug: Evaluate Expression" })
keymap("n", "<leader>dh", function()
	require("dap.ui.widgets").hover()
end, { desc = "Debug: Hover Variables" })
keymap("n", "<leader>dp", function()
	require("dap.ui.widgets").preview()
end, { desc = "Debug: Preview" })

-- Debug Frames & Scopes
keymap("n", "<leader>df", function()
	local widgets = require("dap.ui.widgets")
	widgets.centered_float(widgets.frames)
end, { desc = "Debug: Show Frames" })
keymap("n", "<leader>ds", function()
	local widgets = require("dap.ui.widgets")
	widgets.centered_float(widgets.scopes)
end, { desc = "Debug: Show Scopes" })

-- Lua Debug Server (OSV)
keymap("n", "<leader>dS", function()
	require("osv").launch({ port = 8086 })
end, { desc = "Debug: Start Lua Debug Server" })
