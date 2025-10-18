# popup-juggler.nvim

Switch very quickly between your active buffers. Reimplementation of
[LustyJuggler](https://www.vim.org/scripts/script.php?script_id=2050) in popup written in Lua for
Neovim.

It works the same as the original LustyJuggler: press `<leader>j` to open the popup of recently
opened buffers. Press one of `asdfghjkl;` buttons to select the file and press it again to open.

## Installation

Using `lazy.nvim`:

```lua
{
  "igorgladkoborodov/popup-juggler.nvim",
  opts = {},
  keys = {
    {
      "<leader>j",
      -- Or use the original LustyJuggler shortcut:
      -- "<leader>lj",
      function()
        require("popup-juggler").open()
      end,
      desc = "Popup Juggler",
    },
  },
}
```

## Why

I love LustyJuggler — it’s my primary way to jump between recently opened files. Unfortunately, it
doesn’t work very smoothly in Neovim and sometimes conflicts with key mappings. So I decided to make
my own version of the plugin.

This is a lazy, vibecoded implementation. It probably needs a rewrite someday, but it’s good enough
for me for now.
