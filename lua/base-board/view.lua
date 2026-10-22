-- Renders a board into a scratch buffer: columns side by side, each card a
-- bordered box. The selected card is always read back from the cursor
-- position, so search and other motions work too.

local board_mod = require("base-board.board")

local M = {}

local WIDTH = 36 -- display width of a column, including card borders
local GAP = "  "
local BORDER = "│" -- display width 1
local HEADER_ROW = 3 -- buffer line of the column headers

local HELP = {
  "h/l  previous/next column",
  "j/k  next/previous card",
  "<CR> open card",
  "H/L  move card to previous/next column",
  "J/K  move card down/up",
  "r    refresh",
  "q    close board",
}

local ns = vim.api.nvim_create_namespace("base-board")

local function color_group(prefix, color, spec)
  local name = prefix .. color:gsub("#", "")
  vim.api.nvim_set_hl(0, name, spec)
  return name
end

local function width(text)
  return vim.fn.strdisplaywidth(text)
end

-- Truncates or pads `text` to exactly `w` display cells.
local function fit(text, w)
  if width(text) > w then
    local out = ""
    for _, ch in ipairs(vim.fn.split(text, "\\zs")) do
      if width(out .. ch .. "…") > w then
        break
      end
      out = out .. ch
    end
    text = out .. "…"
  end
  return text .. (" "):rep(w - width(text))
end

local function field_text(value)
  if type(value) == "table" then
    return table.concat(vim.tbl_map(tostring, value), ", ")
  end
  return tostring(value)
end

-- Builds the lines of one column. Each line is a list of {text, hl} segments
-- with a total display width of WIDTH. Records the line range of each card.
local function column_lines(board, column)
  local accent = column.color and color_group("BaseBoardColumn", column.color, { fg = column.color }) or "FloatBorder"
  local count = " " .. #column.cards
  local lines = {
    {
      { "▍", accent },
      { fit(" " .. column.name, WIDTH - 1 - width(count)), "BaseBoardHeader" },
      { count, "BaseBoardMuted" },
    },
    { { (" "):rep(WIDTH) } },
  }
  local inner = WIDTH - 4
  for _, card in ipairs(column.cards) do
    card.top = #lines + 1
    table.insert(lines, { { "╭" .. ("─"):rep(WIDTH - 2) .. "╮", accent } })
    table.insert(lines, {
      { BORDER .. " ", accent },
      { fit(card.note.name, inner), "BaseBoardTitle" },
      { " " .. BORDER, accent },
    })
    local fm = card.note:frontmatter()
    for _, field in ipairs(board.fields) do
      local value = fm[field.key]
      if value ~= nil and value ~= "" and not (type(value) == "table" and #value == 0) then
        local segments = { { BORDER .. " ", accent } }
        if field.key == "tags" then
          local used = 0
          for _, tag in ipairs(type(value) == "table" and value or { value }) do
            local chip = "#" .. tostring(tag)
            if used + width(chip) > inner then
              break
            end
            local color = board.tag_colors[tostring(tag)]
            local hl = color and color_group("BaseBoardTag", color, { fg = "#1e1e2e", bg = color }) or "BaseBoardMuted"
            table.insert(segments, { chip, hl })
            used = used + width(chip)
            if used < inner then
              table.insert(segments, { " " })
              used = used + 1
            end
          end
          table.insert(segments, { (" "):rep(inner - used) })
        else
          local label = field.label .. ": "
          table.insert(segments, { fit(label, math.min(width(label), inner)), "BaseBoardMuted" })
          table.insert(segments, { fit(field_text(value), inner - math.min(width(label), inner)) })
        end
        table.insert(segments, { " " .. BORDER, accent })
        table.insert(lines, segments)
      end
    end
    table.insert(lines, { { "╰" .. ("─"):rep(WIDTH - 2) .. "╯", accent } })
    card.bottom = #lines
  end
  return lines
end

local function define_highlights()
  vim.api.nvim_set_hl(0, "BaseBoardHeader", { default = true, link = "Title" })
  vim.api.nvim_set_hl(0, "BaseBoardTitle", { default = true, bold = true })
  vim.api.nvim_set_hl(0, "BaseBoardMuted", { default = true, link = "Comment" })
end

-- Card line ranges are relative to the first column line; this is the offset.
local function card_row(card, field)
  return HEADER_ROW - 1 + card[field]
end

local function render(state)
  define_highlights()
  local board = state.board
  local columns = {}
  local height = 0
  for i, column in ipairs(board.columns) do
    columns[i] = column_lines(board, column)
    height = math.max(height, #columns[i])
  end

  local total = 0
  for _, column in ipairs(board.columns) do
    total = total + #column.cards
  end
  local lines = { (" %s  ·  %d cards  ·  ? for keys"):format(board.name, total), "" }
  local marks = { { 0, 1, 1 + #board.name, "BaseBoardHeader" } }
  state.offsets = {}
  for row = 1, height do
    local parts = {}
    local byte = 0
    local offsets = {}
    for i, column in ipairs(columns) do
      offsets[i] = byte
      for _, seg in ipairs(column[row] or { { (" "):rep(WIDTH) } }) do
        if seg[2] then
          table.insert(marks, { HEADER_ROW - 2 + row, byte, byte + #seg[1], seg[2] })
        end
        table.insert(parts, seg[1])
        byte = byte + #seg[1]
      end
      if i < #columns then
        table.insert(parts, GAP)
        byte = byte + #GAP
      end
    end
    state.offsets[HEADER_ROW - 1 + row] = offsets
    table.insert(lines, table.concat(parts))
  end

  local buf = state.buf
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, mark in ipairs(marks) do
    vim.api.nvim_buf_set_extmark(buf, ns, mark[1], mark[2], { end_col = mark[3], hl_group = mark[4] })
  end
end

-- Returns the column index and card index (or nil on a header) under the
-- cursor.
local function selection(state)
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  local offsets = state.offsets[row] or state.offsets[HEADER_ROW]
  local ci = 1
  for i, offset in ipairs(offsets) do
    if col >= offset then
      ci = i
    end
  end
  for k, card in ipairs(state.board.columns[ci].cards) do
    if row >= card_row(card, "top") and row <= card_row(card, "bottom") then
      return ci, k
    end
  end
  return ci, nil
end

-- Places the cursor on a card (or the header of an empty column) and scrolls
-- horizontally so the whole column is visible.
local function focus(state, ci, k)
  local card = k and state.board.columns[ci].cards[k]
  local row = card and card_row(card, "top") + 1 or HEADER_ROW
  local col = state.offsets[row][ci] + (card and #(BORDER .. " ") or 0)
  vim.api.nvim_win_set_cursor(0, { row, col })
  local left = (ci - 1) * (WIDTH + #GAP)
  local view = vim.fn.winsaveview()
  local win_width = vim.api.nvim_win_get_width(0)
  if left < view.leftcol then
    view.leftcol = left
  elseif left + WIDTH > view.leftcol + win_width then
    view.leftcol = math.max(0, left + WIDTH - win_width)
  end
  vim.fn.winrestview({ leftcol = view.leftcol })
end

local function focus_path(state, path, fallback_ci)
  for ci, column in ipairs(state.board.columns) do
    for k, card in ipairs(column.cards) do
      if card.note.path == path then
        return focus(state, ci, k)
      end
    end
  end
  local column = state.board.columns[fallback_ci] and fallback_ci or 1
  focus(state, column, #state.board.columns[column].cards > 0 and 1 or nil)
end

local function reload(state)
  local ci, k = selection(state)
  local card = k and state.board.columns[ci].cards[k]
  state.board = board_mod.load(state.board.path)
  render(state)
  focus_path(state, card and card.note.path, ci)
end

local function step_column(state, delta)
  local ci, k = selection(state)
  local target = ci + delta
  if not state.board.columns[target] then
    return
  end
  local count = #state.board.columns[target].cards
  focus(state, target, count > 0 and math.min(k or 1, count) or nil)
end

local function step_card(state, delta)
  local ci, k = selection(state)
  local count = #state.board.columns[ci].cards
  if count == 0 then
    return
  end
  focus(state, ci, math.max(1, math.min(count, (k or 0) + delta)))
end

local function move_card(state, dcol, dindex)
  local ci, k = selection(state)
  if not k then
    return
  end
  local column = state.board.columns[ci]
  local card = column.cards[k]
  local target = state.board.columns[ci + dcol]
  if not target then
    return
  end
  local index
  if dcol ~= 0 then
    index = #target.cards + 1
  else
    index = k + dindex
    if index < 1 or index > #column.cards then
      return
    end
  end
  board_mod.move(state.board, card, target, index)
  state.board = board_mod.load(state.board.path)
  render(state)
  focus_path(state, card.note.path, ci)
end

local function open_card(state)
  local ci, k = selection(state)
  if k then
    vim.cmd.edit(vim.fn.fnameescape(state.board.columns[ci].cards[k].note.path))
  end
end

local function attach(state)
  local buf = state.buf
  local function map(lhs, fn)
    vim.keymap.set("n", lhs, function()
      fn(state)
    end, { buffer = buf, nowait = true })
  end
  map("h", function(s) step_column(s, -1) end)
  map("l", function(s) step_column(s, 1) end)
  map("j", function(s) step_card(s, 1) end)
  map("k", function(s) step_card(s, -1) end)
  map("H", function(s) move_card(s, -1, 0) end)
  map("L", function(s) move_card(s, 1, 0) end)
  map("J", function(s) move_card(s, 0, 1) end)
  map("K", function(s) move_card(s, 0, -1) end)
  map("<CR>", open_card)
  map("r", reload)
  map("q", function() vim.api.nvim_buf_delete(buf, { force = true }) end)
  map("?", function() vim.notify(table.concat(HELP, "\n"), vim.log.levels.INFO, { title = "base-board" }) end)

  -- Notes may have changed while the board was hidden.
  vim.api.nvim_create_autocmd("BufEnter", {
    buffer = buf,
    callback = function()
      reload(state)
    end,
  })
end

--- Opens (or switches to) the board for a `.base` file in the current window.
---@param base_path string
function M.open(base_path)
  local name = "base-board://" .. base_path
  local existing = vim.fn.bufnr(name)
  if existing ~= -1 then
    vim.api.nvim_set_current_buf(existing)
    return
  end

  local board = board_mod.load(base_path)
  local buf = vim.api.nvim_create_buf(true, true)
  vim.api.nvim_buf_set_name(buf, name)
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].filetype = "base-board"
  local state = { buf = buf, board = board }
  render(state)
  vim.api.nvim_set_current_buf(buf)
  for option, value in pairs({
    wrap = false,
    number = false,
    relativenumber = false,
    signcolumn = "no",
    list = false,
    cursorline = false,
    spell = false,
    sidescrolloff = 0,
  }) do
    vim.wo[0][0][option] = value
  end
  attach(state)
  focus_path(state, nil, 1)
end

return M
