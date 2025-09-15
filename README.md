# Ripple LSP for Neovim

This plugin wraps the Ripple VSCode extension to provide LSP support for `.ripple` files in Neovim. It ensures compatibility with Neovim's LSP client and adds helper functions for workspace edits and commands.

## Installation

Using [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "Cliffback/ripple-vscode-plugin.nvim",
  config = function()
    require("ripple-lsp").setup(
      {
        -- optional overrides
        -- on_attach = function(client, bufnr) ... end
        -- treesitter_lang = 'tsx',
        -- set_filetype = true,
      }
    )
  end,
}
```
