# base-board.nvim

<p align="center">
  <a href="https://github.com/zazencodes/base-board.nvim/releases/latest"><img src="https://img.shields.io/github/v/release/zazencodes/base-board.nvim" alt="Latest release"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-GPLv3-blue" alt="License: GPLv3"></a>
  <img src="https://img.shields.io/badge/Neovim-0.11%2B-57A143?logo=neovim&logoColor=white" alt="Neovim 0.11+">
  <img src="https://img.shields.io/badge/Obsidian-Bases-7C3AED?logo=obsidian&logoColor=white" alt="Obsidian Bases">
  <img src="https://img.shields.io/badge/Lua-2C2D72?logo=lua&logoColor=white" alt="Lua">
  <a href="https://zazencodes.com/"><img src="https://img.shields.io/badge/made%20by-ZazenCodes-black" alt="Made by ZazenCodes"></a>
</p>

Kanban boards for Obsidian Bases in Neovim. Works with the same `.base` files and card order as the [Base Board](https://github.com/mderazon/obsidian-base-board) Obsidian plugin.

https://github.com/user-attachments/assets/1535d0ed-1b46-4262-a3a6-3dc37f5cc3b5

## Install

```lua
-- lazy.nvim
{ "zazencodes/base-board.nvim" }
```

## Usage

Opening a `.base` file that has a `type: base-board` view shows its board. `:BaseBoard` toggles between the board and the `.base` file. `:BaseBoard <path>` opens the board for another `.base` file.

| Key | Action |
| --- | --- |
| `h` / `l` | previous / next column |
| `j` / `k` | next / previous card |
| `<CR>` | open card |
| `H` / `L` | move card to previous / next column |
| `J` / `K` | move card down / up |
| `r` | refresh |
| `q` | close |
| `?` | show keys |

## License

[GPLv3](LICENSE). You can use, modify and share this code, and any version you distribute must also be released under GPLv3.

<p align="center">
  <a href="https://zazencodes.com/?utm_source=github&utm_medium=referral&utm_campaign=base-board-nvim">
    <img
      src="docs/assets/zazencodes-banner.png"
      alt="ZazenCodes — Engineering for the Agentic Era"
      width="100%"
    >
  </a>
  <br>
  Created by <a href="https://zazencodes.com/">ZazenCodes</a>
</p>
