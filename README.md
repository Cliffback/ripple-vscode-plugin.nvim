# Ripple LSP for Neovim

This plugin wraps the Ripple VSCode extension to provide LSP support for `.ripple` files in Neovim. It ensures compatibility with Neovim's LSP client and adds helper functions for workspace edits and commands.

## Installation

Using [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "Cliffback/ripple-vscode-plugin.nvim",
}
```

And wherever you setup your lsp:
```lua
require('ripple-lsp').setup({
  on_attach = on_attach_keymaps
})
```



