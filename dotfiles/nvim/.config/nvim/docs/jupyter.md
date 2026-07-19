# Jupyter Notebook Support in Neovim

## Setup (First Time Only)

Enable the Nix `development` profile. It provides Python, Jupyter, pynvim,
jupytext, ImageMagick, and the remaining notebook dependencies. The
`:JupyterInstallDeps` command reports this requirement but does not invoke a
system package manager.

## Keybindings

| Key | Action |
|-----|--------|
| `<leader>;i` | Select/init kernel |
| `<leader>;l` | Evaluate current line |
| `<leader>;v` | Evaluate visual selection |
| `<leader>;r` | Re-evaluate cell |
| `<leader>;a` | Run entire file |
| `<leader>;o` | Show output |
| `<leader>;e` | Enter output window (navigate) |
| `<leader>;h` | Hide output |
| `<leader>;d` | Delete cell |
| `<leader>;n` | New cell below (# %%) |
| `<leader>;N` | New cell above (# %%) |
| `<leader>;m` | New code fence below (markdown) |
| `<leader>;M` | New code fence above (markdown) |
| `<leader>;k` | Kernel info |
| `<leader>;x` | Stop kernel |
| `<leader>;t` | Toggle ghost text output |

## Usage

### Opening Jupyter Notebooks (.ipynb)

Just open the file - jupytext automatically converts it to Python:

```bash
nvim notebook.ipynb
```

### Working with Python Files (.py)

Use `# %%` to mark cells:

```python
# %% Cell 1 - Imports
import numpy as np
import matplotlib.pyplot as plt

# %% Cell 2 - Data
x = np.linspace(0, 10, 100)
y = np.sin(x)

# %% Cell 3 - Plot
plt.plot(x, y)
plt.show()
```

### Workflow

1. Open `.ipynb` or `.py` file
2. `<leader>;i` → select kernel
3. Select code visually (`V` for line, `v` for char)
4. `<leader>;v` to execute
5. Output appears in popup (press `Esc` to close)

### Changing Kernel

1. `<leader>;x` - Stop current kernel
2. `<leader>;i` - Select new kernel

### Register Project Venv as Kernel

```vim
:JupyterRegisterVenv
```

This registers your project's `venv/` or `.venv/` as a Jupyter kernel.

## Requirements

- **Kitty terminal** (for inline images) or WezTerm
- **ImageMagick** (provided by the Nix development profile)

## Troubleshooting

### Check health
```vim
:Lazy load molten-nvim
:checkhealth molten
```

### No kernels found

`:JupyterInstallDeps` explains which Nix profile to enable.

Then restart Neovim.

### Images not showing
- Ensure you're using Kitty terminal
- Or change `backend = "ueberzug"` in `lua/plugins/jupyter.lua`

## Commands

| Command | Description |
|---------|-------------|
| `:JupyterInstallDeps` | Show the Nix dependency guidance |
| `:JupyterRegisterVenv` | Register project venv as kernel |
| `:JupyterLab` | Launch JupyterLab in browser |
| `:MoltenInit` | Initialize kernel |
| `:MoltenInfo` | Show kernel info |
| `:MoltenDeinit` | Stop kernel |
