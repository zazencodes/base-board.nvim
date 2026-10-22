-- Run with: nvim --clean --headless -l tests/run.lua
-- Copies the fixture vault to a temp directory and exercises the plugin.

local root = vim.fs.dirname(vim.fs.dirname(vim.fs.abspath(arg[0])))
vim.opt.rtp:prepend(root)
vim.cmd.runtime("plugin/base-board.lua")

local failures = 0
local function test(name, fn)
  local ok, err = pcall(fn)
  io.stdout:write((ok and "ok   " or "FAIL ") .. name .. (ok and "" or ("\n     " .. tostring(err))) .. "\n")
  if not ok then
    failures = failures + 1
  end
end

local function eq(got, want)
  if not vim.deep_equal(got, want) then
    error(("expected %s, got %s"):format(vim.inspect(want), vim.inspect(got)), 2)
  end
end

local function fresh_vault()
  local dir = vim.fn.tempname()
  vim.fn.system({ "cp", "-R", root .. "/tests/vault", dir })
  return dir
end

local function frontmatter(path)
  local lines = vim.fn.readfile(path)
  local close = vim.fn.index(lines, "---", 1)
  return require("base-board.yaml").parse(table.concat(vim.list_slice(lines, 2, close), "\n"))
end

local function names(column)
  return vim.tbl_map(function(card)
    return card.note.name
  end, column.cards)
end

local yaml = require("base-board.yaml")
local order = require("base-board.order")
local board = require("base-board.board")

test("yaml parses nested mappings, sequences and scalars", function()
  eq(
    yaml.parse(table.concat({
      "a:",
      "  - type: x",
      "    list:",
      "      - '!q.isEmpty()'",
      '      - "#hex"',
      "b: [one, 2]",
      "c: 3 # comment",
      "d: In progress",
      "e:",
    }, "\n")),
    { a = { { type = "x", list = { "!q.isEmpty()", "#hex" } } }, b = { "one", 2 }, c = 3, d = "In progress" }
  )
end)

test("yaml rejects unsupported syntax", function()
  eq(pcall(yaml.parse, "a: |\n  text"), false)
end)

test("order keys match Base Board (fractional-indexing, base 62)", function()
  -- Expected values generated with Base Board 2.6.1's bundled implementation.
  eq(order.key_between(nil, nil), "V0")
  eq(order.key_between("V0", nil), "V1")
  eq(order.key_between(nil, "V0"), "Uz")
  eq(order.key_between("V0", "V1"), "V0V")
  eq(order.keys_between(nil, nil, 3), { "V0", "V1", "V2" })
  eq(order.is_key("V0"), true)
  eq(order.is_key(3), false)
end)

test("board groups, filters and sorts cards like Base Board", function()
  local b = board.load(fresh_vault() .. "/Board/Board.base")
  eq(vim.tbl_map(function(c) return c.name end, b.columns), { "Doing", "Backlog", "Done", "Review" })
  eq(names(b.columns[1]), { "Gamma", "Delta", "Ship it" })
  eq(names(b.columns[2]), { "Beta", "Alpha" })
  eq(names(b.columns[3]), {})
  eq(names(b.columns[4]), { "Waiting" })
  eq(b.columns[1].color, "#9e2ff9")
  eq(vim.tbl_map(function(f) return f.label end, b.fields), { "Post date", "tags" })
end)

test("moving within a column with keyed neighbours writes one key", function()
  local vault = fresh_vault()
  local b = board.load(vault .. "/Board/Board.base")
  local doing = b.columns[1]
  board.move(b, doing.cards[3], doing, 1) -- Ship it to the top
  eq(frontmatter(vault .. "/Board/tasks/Ship it/Ship it.md").kanban_order, "Uz")
  eq(frontmatter(vault .. "/Board/tasks/Gamma.md").kanban_order, "V0")
  eq(names(board.load(vault .. "/Board/Board.base").columns[1]), { "Ship it", "Gamma", "Delta" })
end)

test("moving into a column with legacy numbers renumbers it", function()
  local vault = fresh_vault()
  local b = board.load(vault .. "/Board/Board.base")
  board.move(b, b.columns[1].cards[1], b.columns[2], 3) -- Gamma to the end of Backlog
  eq(frontmatter(vault .. "/Board/tasks/Gamma.md"), { status = "Backlog", kanban_order = "V2", tags = { "dedicated" } })
  eq(frontmatter(vault .. "/Board/tasks/Beta.md").kanban_order, "V0")
  eq(frontmatter(vault .. "/Board/tasks/Alpha.md").kanban_order, "V1")
  local lines = vim.fn.readfile(vault .. "/Board/tasks/Gamma.md")
  eq(lines[#lines], "Body of Gamma")
end)

test("moving into an empty column", function()
  local vault = fresh_vault()
  local b = board.load(vault .. "/Board/Board.base")
  board.move(b, b.columns[2].cards[1], b.columns[3], 1) -- Beta to Done
  eq(frontmatter(vault .. "/Board/tasks/Beta.md"), { status = "Done", kanban_order = "V0", post_date = "2026-06-17" })
end)

test("unsupported filters fail loudly", function()
  local vault = fresh_vault()
  local path = vault .. "/Board/Board.base"
  local text = table.concat(vim.fn.readfile(path), "\n"):gsub('file%.ext == "md"', "file.size > 10")
  vim.fn.writefile(vim.split(text, "\n"), path)
  local ok, err = pcall(board.load, path)
  eq(ok, false)
  assert(err:match("unsupported filter"), err)
end)

test(":BaseBoard renders the board and keys move cards", function()
  local vault = fresh_vault()
  vim.cmd("BaseBoard " .. vim.fn.fnameescape(vault .. "/Board/Board.base"))
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  assert(lines[1]:match("Test Board  ·  6 cards"), lines[1])
  assert(lines[3]:match("▍ Doing +3") and lines[3]:match("▍ Backlog +2"), lines[3])
  local text = table.concat(lines, "\n")
  assert(text:match("│ Gamma "), "missing Gamma card")
  assert(text:match("Post date: 2026%-06%-17"), "missing post date field")
  assert(text:match("#dedicated"), "missing tag chip")

  -- Cursor starts on Gamma; L moves it to the end of Backlog.
  vim.api.nvim_feedkeys("L", "x", false)
  eq(frontmatter(vault .. "/Board/tasks/Gamma.md").status, "Backlog")
  -- The cursor follows the card: K moves it up above Alpha.
  vim.api.nvim_feedkeys("K", "x", false)
  local backlog = board.load(vault .. "/Board/Board.base").columns[2]
  eq(names(backlog), { "Beta", "Gamma", "Alpha" })

  -- <CR> opens the card under the cursor.
  vim.api.nvim_feedkeys("\r", "x", false)
  eq(vim.uv.fs_realpath(vim.api.nvim_buf_get_name(0)), vim.uv.fs_realpath(vault .. "/Board/tasks/Gamma.md"))
end)

if failures > 0 then
  io.stdout:write(failures .. " test(s) failed\n")
  os.exit(1)
end
io.stdout:write("all tests passed\n")
