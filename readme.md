# foil.nvim

Like Oil, but without boundaries.

Foil.nvim is a lightweight Neovim plugin that lets you batch-rename files using a buffer-driven workflow. Heavily inspired by oil.nvim and its approach of “editing your filesystem like a buffer,” foil.nvim focuses on efficiently renaming multiple files at once.

## Installation

```lua
require('lazy').setup({
  {
    dir = '~/projects/foil.nvim',
    opts = {},
  }
})
```

## Usage

Foil.nvim introduces two commands:

### FoilQuickfix

Will open a floating window with all files currently open in the quickfix list

### FoilArgs

Will open a floating window with all files currently open in the args list
