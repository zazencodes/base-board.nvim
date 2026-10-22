# base-board.nvim

Kanban boards for Obsidian Bases in Neovim, compatible with the
[Base Board](https://github.com/mderazon/obsidian-base-board) Obsidian plugin.

It reads the `type: base-board` view of a `.base` file and draws its
columns and cards in a buffer. Moving a card writes the same frontmatter Base
Board writes (the group-by property and `kanban_order`), so the board stays in
sync with Obsidian.

## Usage

`:BaseBoard [file]` opens the board for a `.base` file (default: the current
buffer).

| Key | Action |
| --- | --- |
| `h` / `l` | previous / next column |
| `j` / `k` | next / previous card |
| `<CR>` | open the card's note |
| `H` / `L` | move the card to the end of the previous / next column |
| `J` / `K` | move the card down / up |
| `r` | refresh |
| `q` | close the board |
| `?` | show these keys |

The board refreshes whenever you return to it.

## What it reads

- **View:** the single view with `type: base-board`. More than one is an error.
- **Columns:** values of `groupBy.property`, in `boardColumns` order, with any
  other values appended. Notes without a value go in `(No value)`.
- **Card order:** `kanban_order`, sorted and written the way Base Board does it
  (fractional-indexing keys; legacy numeric values sort first and a column
  holding them is renumbered when you reorder it).
- **Card fields:** the properties in the view's `order`, labelled with
  `displayName`. `tags` render as chips coloured by `tagColors`.
- **Colours:** `columnColors` for column accents and card borders.
- **Filters:** the file's and the view's `filters`, as `and` / `or` / `not`
  groups of `file.inFolder("…")`, `<prop>.isEmpty()`,
  `<prop> == <literal>`, `<prop> != <literal>` and `!<expr>`. Any other
  expression is an error rather than a silently different board.

## Install (lazy.nvim)

```lua
{ dir = "~/pro/base-board.nvim", cmd = "BaseBoard" }
```

Requires Neovim 0.11+. No dependencies.

## Tests

```sh
nvim --clean --headless -l tests/run.lua
```
