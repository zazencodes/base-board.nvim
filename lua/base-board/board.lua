-- Builds a board from a `.base` file and moves cards on it. Mirrors the
-- Obsidian Base Board plugin: the view is the one with `type: base-board`,
-- columns come from `groupBy`, ordered by `boardColumns` with any other
-- values appended, and cards are sorted by `kanban_order`.

local filter = require("base-board.filter")
local order = require("base-board.order")
local vault = require("base-board.vault")
local yaml = require("base-board.yaml")

local M = {}

M.VIEW_TYPE = "base-board"
M.NO_VALUE = "(No value)"

local function strip_note_prefix(prop)
  return (prop:gsub("^note%.", ""))
end

local function column_name(value)
  if value == nil or value == "" then
    return M.NO_VALUE
  end
  if type(value) == "table" then
    error("base-board: list values cannot be grouped into columns", 0)
  end
  return tostring(value)
end

local function card_fields(base, view, group_by)
  local fields = {}
  local properties = base.properties or {}
  for _, prop in ipairs(view.order or {}) do
    local key = strip_note_prefix(prop)
    if prop ~= "file.name" and key ~= group_by and key ~= order.PROPERTY then
      if prop:match("^file%.") or prop:match("^formula%.") then
        error("base-board: card property " .. prop .. " is not supported", 0)
      end
      local display = properties["note." .. key] or properties[key] or {}
      table.insert(fields, { key = key, label = display.displayName or key })
    end
  end
  return fields
end

local function sort_cards(cards)
  table.sort(cards, function(a, b)
    local c = order.compare(a.order, b.order)
    if c ~= 0 then
      return c < 0
    end
    if a.ctime ~= b.ctime then
      return a.ctime < b.ctime
    end
    return order.less(a.note.rel, b.note.rel)
  end)
end

local function board_views(base_path)
  local base = yaml.parse(table.concat(vim.fn.readfile(base_path), "\n"))
  return base, vim.tbl_filter(function(v)
    return v.type == M.VIEW_TYPE
  end, base.views or {})
end

--- Whether a `.base` file has a view with `type: base-board`.
---@param base_path string
---@return boolean
function M.is_board(base_path)
  local _, views = board_views(base_path)
  return #views > 0
end

---@param base_path string  absolute path to a `.base` file
---@return table board
function M.load(base_path)
  local base, views = board_views(base_path)
  if #views ~= 1 then
    error(("base-board: %s needs exactly one view with type: %s (found %d)"):format(base_path, M.VIEW_TYPE, #views), 0)
  end
  local view = views[1]
  if not (view.groupBy and view.groupBy.property) then
    error("base-board: view " .. view.name .. " has no groupBy property", 0)
  end
  local group_by = strip_note_prefix(view.groupBy.property)
  local filters = { ["and"] = {} }
  if base.filters then
    table.insert(filters["and"], base.filters)
  end
  if view.filters then
    table.insert(filters["and"], view.filters)
  end

  local root = vault.root(base_path)
  local by_column = {}
  for _, note in ipairs(vault.notes(root)) do
    if filter.matches(filters, note) then
      local fm = note:frontmatter()
      local name = column_name(fm[group_by])
      by_column[name] = by_column[name] or {}
      table.insert(by_column[name], {
        note = note,
        order = order.read(fm[order.PROPERTY]),
        ctime = vim.uv.fs_stat(note.path).birthtime.sec,
      })
    end
  end

  local data_columns = vim.tbl_keys(by_column)
  table.sort(data_columns, function(a, b)
    if view.groupBy.direction == "DESC" then
      return order.less(b, a)
    end
    return order.less(a, b)
  end)
  local names = {}
  for _, name in ipairs(view.boardColumns or {}) do
    table.insert(names, name == "" and M.NO_VALUE or name)
  end
  for _, name in ipairs(data_columns) do
    if not vim.tbl_contains(names, name) then
      table.insert(names, name)
    end
  end

  local columns = {}
  for _, name in ipairs(names) do
    local cards = by_column[name] or {}
    sort_cards(cards)
    table.insert(columns, { name = name, cards = cards, color = (view.columnColors or {})[name] })
  end

  return {
    path = base_path,
    name = view.name,
    group_by = group_by,
    columns = columns,
    fields = card_fields(base, view, group_by),
    tag_colors = view.tagColors or {},
  }
end

-- Writes `kanban_order` for the cards in `paths_to_assign`, which sit as a
-- contiguous block in `ordered` (the column's new order). Like Base Board, if
-- any other card in the column has no fractional key, the whole column is
-- renumbered.
local function write_order(ordered, paths_to_assign, current)
  local start = vim.fn.index(ordered, paths_to_assign[1]) + 1
  local prev = ordered[start - 1]
  local next = ordered[start + #paths_to_assign]
  local legacy = false
  for _, path in ipairs(ordered) do
    if not vim.tbl_contains(paths_to_assign, path) and not order.is_key(current[path]) then
      legacy = true
    end
  end
  if legacy then
    local keys = order.keys_between(nil, nil, #ordered)
    for i, path in ipairs(ordered) do
      vault.set_properties(path, { [order.PROPERTY] = keys[i] })
    end
    return
  end
  local before = prev and order.is_key(current[prev]) and current[prev] or nil
  local after = next and order.is_key(current[next]) and current[next] or nil
  local keys = order.keys_between(before, after, #paths_to_assign)
  for i, path in ipairs(paths_to_assign) do
    vault.set_properties(path, { [order.PROPERTY] = keys[i] })
  end
end

--- Moves a card to `index` (1-based) in the column `target`.
---@param board table
---@param card table
---@param target table  a column of `board`
---@param index integer
function M.move(board, card, target, index)
  local ordered, current = {}, {}
  for _, other in ipairs(target.cards) do
    if other ~= card then
      table.insert(ordered, other.note.path)
      current[other.note.path] = other.order
    end
  end
  table.insert(ordered, index, card.note.path)
  current[card.note.path] = card.order

  local fm = card.note:frontmatter()
  if column_name(fm[board.group_by]) ~= target.name then
    vault.set_properties(card.note.path, {
      [board.group_by] = target.name == M.NO_VALUE and vim.NIL or target.name,
    })
  end
  write_order(ordered, { card.note.path }, current)
end

return M
