-- ============================================================================
-- Mason Package Manager & Markdown Keybindings (Namespace: <leader>m)
-- ============================================================================

local keymap = vim.keymap.set

-- Markdown Preview
keymap("n", "<leader>mp", "<cmd>MarkdownPreviewToggle<cr>", { desc = "Markdown: Preview Toggle" })
keymap("n", "<leader>ms", "<cmd>MarkdownPreview<cr>", { desc = "Markdown: Preview Start" })
keymap("n", "<leader>mx", "<cmd>MarkdownPreviewStop<cr>", { desc = "Markdown: Preview Stop" })

-- Mason UI
keymap("n", "<leader>mm", "<cmd>Mason<cr>", { desc = "Mason: Open" })
keymap("n", "<leader>mi", "<cmd>MasonInstall<cr>", { desc = "Mason: Install" })
keymap("n", "<leader>mu", "<cmd>MasonUpdate<cr>", { desc = "Mason: Update" })
keymap("n", "<leader>mU", "<cmd>MasonUninstall<cr>", { desc = "Mason: Uninstall" })
keymap("n", "<leader>ml", "<cmd>MasonLog<cr>", { desc = "Mason: Log" })

-- Quick Install Sets (Language-specific)
-- Python
keymap("n", "<leader>mip", "<cmd>MasonInstall pyright debugpy ruff black<cr>", { desc = "Mason: Install Python" })

-- JavaScript/TypeScript
keymap(
	"n",
	"<leader>miw",
	"<cmd>MasonInstall typescript-language-server vtsls eslint-lsp prettier<cr>",
	{ desc = "Mason: Install Web Dev" }
)

-- Go
keymap("n", "<leader>mig", "<cmd>MasonInstall gopls golangci-lint delve<cr>", { desc = "Mason: Install Go" })

-- Rust
keymap("n", "<leader>mir", "<cmd>MasonInstall rust-analyzer codelldb<cr>", { desc = "Mason: Install Rust" })

-- Java
keymap("n", "<leader>mij", "<cmd>MasonInstall jdtls java-debug-adapter<cr>", { desc = "Mason: Install Java" })

-- Lua
keymap("n", "<leader>mil", "<cmd>MasonInstall lua-language-server stylua<cr>", { desc = "Mason: Install Lua" })

-- Bash/Shell
keymap("n", "<leader>mib", "<cmd>MasonInstall bash-language-server shellcheck shfmt<cr>", { desc = "Mason: Install Bash" })

-- Docker
keymap("n", "<leader>mid", "<cmd>MasonInstall dockerfile-language-server docker-compose-language-service<cr>", { desc = "Mason: Install Docker" })

-- Config Files (JSON, YAML, TOML)
keymap(
	"n",
	"<leader>mic",
	"<cmd>MasonInstall json-lsp yaml-language-server taplo<cr>",
	{ desc = "Mason: Install Config Files" }
)

-- SQL
keymap("n", "<leader>mis", "<cmd>MasonInstall sqlls sqlfluff<cr>", { desc = "Mason: Install SQL" })

-- Markdown
keymap("n", "<leader>mim", "<cmd>MasonInstall marksman markdownlint<cr>", { desc = "Mason: Install Markdown" })

-- Install All
keymap("n", "<leader>mia", function()
	vim.cmd([[
    MasonInstall pyright debugpy ruff black
    MasonInstall typescript-language-server vtsls eslint-lsp prettier
    MasonInstall gopls golangci-lint delve
    MasonInstall rust-analyzer codelldb
    MasonInstall jdtls java-debug-adapter
    MasonInstall lua-language-server stylua
    MasonInstall bash-language-server shellcheck shfmt
    MasonInstall dockerfile-language-server docker-compose-language-service
    MasonInstall json-lsp yaml-language-server taplo
    MasonInstall sqlls sqlfluff
    MasonInstall marksman markdownlint
  ]])
end, { desc = "Mason: Install All Languages" })

-- Uninstall Sets (Language-specific)
-- Python
keymap("n", "<leader>mup", "<cmd>MasonUninstall pyright debugpy ruff black<cr>", { desc = "Mason: Uninstall Python" })

-- JavaScript/TypeScript
keymap(
	"n",
	"<leader>muw",
	"<cmd>MasonUninstall typescript-language-server vtsls eslint-lsp prettier<cr>",
	{ desc = "Mason: Uninstall Web Dev" }
)

-- Go
keymap("n", "<leader>mug", "<cmd>MasonUninstall gopls golangci-lint delve<cr>", { desc = "Mason: Uninstall Go" })

-- Rust
keymap("n", "<leader>mur", "<cmd>MasonUninstall rust-analyzer codelldb<cr>", { desc = "Mason: Uninstall Rust" })

-- Java
keymap("n", "<leader>muj", "<cmd>MasonUninstall jdtls java-debug-adapter<cr>", { desc = "Mason: Uninstall Java" })

-- Lua
keymap("n", "<leader>mul", "<cmd>MasonUninstall lua-language-server stylua<cr>", { desc = "Mason: Uninstall Lua" })

-- Bash/Shell
keymap("n", "<leader>mub", "<cmd>MasonUninstall bash-language-server shellcheck shfmt<cr>", { desc = "Mason: Uninstall Bash" })

-- Docker
keymap(
	"n",
	"<leader>mud",
	"<cmd>MasonUninstall dockerfile-language-server docker-compose-language-service<cr>",
	{ desc = "Mason: Uninstall Docker" }
)

-- Config Files
keymap(
	"n",
	"<leader>muc",
	"<cmd>MasonUninstall json-lsp yaml-language-server taplo<cr>",
	{ desc = "Mason: Uninstall Config Files" }
)

-- SQL
keymap("n", "<leader>mus", "<cmd>MasonUninstall sqlls sqlfluff<cr>", { desc = "Mason: Uninstall SQL" })

-- Markdown
keymap("n", "<leader>mum", "<cmd>MasonUninstall marksman markdownlint<cr>", { desc = "Mason: Uninstall Markdown" })

-- Uninstall All
keymap("n", "<leader>mua", function()
	local ok, registry = pcall(require, "mason-registry")
	if not ok then
		vim.notify("Mason registry not available", vim.log.levels.ERROR)
		return
	end

	local installed = registry.get_installed_packages()
	if #installed == 0 then
		vim.notify("No packages to uninstall", vim.log.levels.INFO)
		return
	end

	for _, pkg in ipairs(installed) do
		pcall(function()
			pkg:uninstall()
		end)
	end
	vim.notify("Uninstalled all Mason packages", vim.log.levels.INFO)
end, { desc = "Mason: Uninstall ALL" })

-- Reinstall All
keymap("n", "<leader>mra", function()
	local ok, registry = pcall(require, "mason-registry")
	if not ok then
		vim.notify("Mason registry not available", vim.log.levels.ERROR)
		return
	end

	vim.notify("Uninstalling all tools...", vim.log.levels.INFO)
	local installed = registry.get_installed_packages()
	local pkg_names = {}

	for _, pkg in ipairs(installed) do
		table.insert(pkg_names, pkg.name)
		pcall(function()
			pkg:uninstall()
		end)
	end

	vim.defer_fn(function()
		vim.notify("Reinstalling all tools...", vim.log.levels.INFO)
		for _, name in ipairs(pkg_names) do
			vim.cmd("MasonInstall " .. name)
		end
	end, 2000)
end, { desc = "Mason: Reinstall ALL" })
