# AGENTS.md

base-board.nvim: Neovim plugin (Lua, no dependencies) that shows Obsidian `.base` files with a `type: base-board` view as kanban boards and moves cards by editing note frontmatter. See `README.md` for behavior.

## Project Instructions

- Compatibility with the Obsidian Base Board plugin is the point. Card order (`kanban_order`), column order and filters must match what Base Board shows and writes. When in doubt, read Base Board's source (github.com/mderazon/obsidian-base-board).
- Fail loudly with `error("base-board: ...", 0)` on anything unsupported (YAML syntax, filter expressions, nested frontmatter values). Do not add silent fallbacks.
- User-facing changes (commands, keys, supported filters) must be reflected in `README.md`.

## Layout

- `plugin/base-board.lua`: the `:BaseBoard` command only.
- `lua/base-board/yaml.lua`: block-style YAML subset parser for `.base` files and frontmatter.
- `lua/base-board/filter.lua`: Bases filter evaluator.
- `lua/base-board/order.lua`: port of Base Board's fractional-indexing order keys.
- `lua/base-board/vault.lua`: vault root, note scanning, frontmatter read/write.
- `lua/base-board/board.lua`: builds a board from a `.base` file; moves cards.
- `lua/base-board/view.lua`: renders the board buffer and its keymaps.

## Testing

Run `nvim --clean --headless -l tests/run.lua`. It copies `tests/vault/` to a temp directory, so tests never touch a real vault.
