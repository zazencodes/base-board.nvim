-- Renders a board into a scratch buffer: columns as shaded panels with a
-- colored top edge, each card a filled block. Colors are derived from the
-- colorscheme's Normal group. The selected card is always read back from the
-- cursor position, so search and other motions work too.

local board_mod = require("base-board.board")

local M = {}

M.PREFIX = "base-board://"

local WIDTH = 34 -- display width of a column panel
local GAP = "  "
local CARD = WIDTH - 2 -- display width of a card; the panel pads it by 1
local INNER = CARD - 2 -- display width of a card's text
local TITLE_LINES = 3
local TOP = 2 -- buffer lines above the columns
local HEADER_ROW = TOP + 2 -- buffer line of the column headers

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

-- Colors -------------------------------------------------------------------

local function to_hex(n)
  return ("#%06x"):format(n)
end

local function channels(hex)
  return tonumber(hex:sub(2, 3), 16), tonumber(hex:sub(4, 5), 16), tonumber(hex:sub(6, 7), 16)
end

-- Mixes `t` of color `b` into color `a`.
local function blend(a, b, t)
  local ar, ag, ab = channels(a)
  local br, bg, bb = channels(b)
  local function mix(x, y)
    return math.floor(x + (y - x) * t + 0.5)
  end
  return ("#%02x%02x%02x"):format(mix(ar, br), mix(ag, bg), mix(ab, bb))
end

-- Text color for a chip, chosen like Base Board by the background's luminance.
local function chip_fg(hex)
  local r, g, b = channels(hex)
  return (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255 > 0.5 and "#1a1a1a" or "#ffffff"
end

-- Defines the shared highlight groups and returns the palette.
local function palette()
  local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
  -- Without a Normal background the terminal's own shows through.
  local dark = vim.o.background == "dark"
  local bg = normal.bg and to_hex(normal.bg) or (dark and "#000000" or "#ffffff")
  local fg = normal.fg and to_hex(normal.fg) or (dark and "#ffffff" or "#000000")
  local p = {
    bg = bg,
    fg = fg,
    panel = blend(bg, fg, 0.04),
    card = blend(bg, fg, 0.09),
    muted = blend(fg, bg, 0.45),
  }
  local set = vim.api.nvim_set_hl
  set(0, "BaseBoardTitle", { fg = fg, bold = true })
  set(0, "BaseBoardMuted", { fg = p.muted })
  set(0, "BaseBoardPanel", { bg = p.panel })
  set(0, "BaseBoardPanelEdge", { fg = p.panel })
  set(0, "BaseBoardColumnTitle", { fg = fg, bg = p.panel, bold = true })
  set(0, "BaseBoardPanelMuted", { fg = p.muted, bg = p.panel })
  set(0, "BaseBoardCard", { fg = fg, bg = p.card })
  set(0, "BaseBoardCardTitle", { fg = fg, bg = p.card, bold = true })
  set(0, "BaseBoardCardMuted", { fg = p.muted, bg = p.card })
  set(0, "BaseBoardCardEdge", { fg = p.card, bg = p.panel })
  return p
end

-- Highlight groups for one column's accent color, plain and for its selected
-- card.
local function accent_groups(p, accent)
  local id = accent:gsub("#", "")
  local sel = blend(p.card, accent, 0.18)
  local groups = {
    accent = { "BaseBoardAccent" .. id, { fg = accent, bg = p.panel } },
    count = { "BaseBoardCount" .. id, { fg = accent, bg = blend(p.panel, accent, 0.2), bold = true } },
    sel = { "BaseBoardSel" .. id, { fg = p.fg, bg = sel } },
    sel_title = { "BaseBoardSelTitle" .. id, { fg = p.fg, bg = sel, bold = true } },
    sel_muted = { "BaseBoardSelMuted" .. id, { fg = p.muted, bg = sel } },
    sel_edge = { "BaseBoardSelEdge" .. id, { fg = sel, bg = p.panel } },
    sel_bar = { "BaseBoardSelBar" .. id, { bg = accent } },
    sel_bar_edge = { "BaseBoardSelBarEdge" .. id, { fg = accent, bg = p.panel } },
  }
  local names = {}
  for key, group in pairs(groups) do
    vim.api.nvim_set_hl(0, group[1], group[2])
    names[key] = group[1]
  end
  return names
end

local function tag_group(color)
  local name = "BaseBoardTag" .. color:gsub("#", "")
  vim.api.nvim_set_hl(0, name, { fg = chip_fg(color), bg = color })
  return name
end

-- Text ---------------------------------------------------------------------

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

-- Word-wraps `text` into at most `max` lines of `w` cells; the last line ends
-- in an ellipsis if text is left over.
local function wrap(text, w, max)
  local lines = {}
  local line = ""
  for _, word in ipairs(vim.split(text, " ", { trimempty = true })) do
    local candidate = line == "" and word or (line .. " " .. word)
    if width(candidate) <= w then
      line = candidate
    else
      if line ~= "" then
        table.insert(lines, line)
      end
      line = word
      while width(line) > w do
        local head = vim.fn.strcharpart(line, 0, w)
        while width(head) > w do
          head = vim.fn.strcharpart(head, 0, vim.fn.strchars(head) - 1)
        end
        table.insert(lines, head)
        line = vim.fn.strcharpart(line, vim.fn.strchars(head))
      end
    end
  end
  if line ~= "" then
    table.insert(lines, line)
  end
  if #lines > max then
    lines = vim.list_slice(lines, 1, max)
    local last = lines[max]
    while width(last .. "…") > w do
      last = vim.fn.strcharpart(last, 0, vim.fn.strchars(last) - 1)
    end
    lines[max] = vim.trim(last) .. "…"
  end
  return lines
end

local function field_text(value)
  if type(value) == "table" then
    return table.concat(vim.tbl_map(tostring, value), ", ")
  end
  return tostring(value)
end

-- Layout -------------------------------------------------------------------

-- A segment is { text, hl, sel_hl }: `sel_hl` replaces `hl` while the
-- segment's card is selected. Each column line is a list of segments with a
-- total display width of WIDTH.

-- The lines of one card, each CARD cells wide: a half-block top edge, the
-- tags, the wrapped title, the fields and a half-block bottom edge.
local function card_lines(board, card, g)
  local fm = card.note:frontmatter()
  local function row(segments)
    local line = { { " ", "BaseBoardCard", g.sel_bar } }
    vim.list_extend(line, segments)
    table.insert(line, { " ", "BaseBoardCard", g.sel })
    return line
  end
  local lines = {
    { { "▄", "BaseBoardCardEdge", g.sel_bar_edge }, { ("▄"):rep(CARD - 1), "BaseBoardCardEdge", g.sel_edge } },
  }

  local tags = board_mod.tags(fm)
  if #tags > 0 then
    local segments, used = {}, 0
    for _, tag in ipairs(tags) do
      local chip = " " .. tag .. " "
      local gap = used > 0 and 1 or 0
      if used + gap + width(chip) > INNER then
        break
      end
      if gap > 0 then
        table.insert(segments, { " ", "BaseBoardCard", g.sel })
      end
      table.insert(segments, { chip, tag_group(board_mod.tag_color(board, tag)) })
      used = used + gap + width(chip)
    end
    table.insert(segments, { (" "):rep(INNER - used), "BaseBoardCard", g.sel })
    table.insert(lines, row(segments))
  end

  card.title_line = #lines + 1
  for _, text in ipairs(wrap(card.note.name, INNER, TITLE_LINES)) do
    table.insert(lines, row({ { fit(text, INNER), "BaseBoardCardTitle", g.sel_title } }))
  end

  for _, field in ipairs(board.fields) do
    local value = fm[field.key]
    if value ~= nil and value ~= "" and not (type(value) == "table" and #value == 0) then
      local label = field.label .. "  "
      local label_w = math.min(width(label), INNER)
      table.insert(
        lines,
        row({
          { fit(label, label_w), "BaseBoardCardMuted", g.sel_muted },
          { fit(field_text(value), INNER - label_w), "BaseBoardCard", g.sel },
        })
      )
    end
  end

  table.insert(lines, {
    { "▀", "BaseBoardCardEdge", g.sel_bar_edge },
    { ("▀"):rep(CARD - 1), "BaseBoardCardEdge", g.sel_edge },
  })
  return lines
end

-- Builds the lines of one column panel and records each card's line range
-- (relative to the panel) in the card.
local function column_lines(board, column, p)
  local accent = column.color or p.muted
  local g = accent_groups(p, accent)
  local count = " " .. #column.cards .. " "
  local function blank()
    return { { (" "):rep(WIDTH), "BaseBoardPanel" } }
  end
  local lines = {
    { { ("▀"):rep(WIDTH), g.accent } },
    {
      { " ", "BaseBoardPanel" },
      { fit(column.name, WIDTH - 3 - width(count)), "BaseBoardColumnTitle" },
      { count, g.count },
      { "  ", "BaseBoardPanel" },
    },
    blank(),
  }
  if #column.cards == 0 then
    table.insert(lines, { { " ", "BaseBoardPanel" }, { fit("No cards", WIDTH - 1), "BaseBoardPanelMuted" } })
  end
  for _, card in ipairs(column.cards) do
    card.top = #lines + 1
    for _, line in ipairs(card_lines(board, card, g)) do
      local panel_line = { { " ", "BaseBoardPanel" } }
      for _, seg in ipairs(line) do
        table.insert(panel_line, { seg[1], seg[2], seg[3], card = card })
      end
      table.insert(panel_line, { " ", "BaseBoardPanel" })
      table.insert(lines, panel_line)
    end
    card.bottom = #lines
    card.title_line = card.top + card.title_line - 1
  end
  table.insert(lines, { { ("▀"):rep(WIDTH), "BaseBoardPanelEdge" } })
  return lines
end

-- Card line ranges are relative to the first column line; this is the offset.
local function card_row(card, field)
  return TOP + card[field]
end

-- Highlights the board, with `selected` (a card or nil) in its selected style.
local function paint(state, selected)
  local buf = state.buf
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, mark in ipairs(state.marks) do
    local hl = mark.card == selected and mark.sel_hl or mark.hl
    vim.api.nvim_buf_set_extmark(buf, ns, mark.row, mark.start, { end_col = mark.stop, hl_group = hl })
  end
  state.painted = selected
end

local function render(state)
  local p = palette()
  local board = state.board
  local columns = {}
  local height = 0
  for i, column in ipairs(board.columns) do
    columns[i] = column_lines(board, column, p)
    height = math.max(height, #columns[i])
  end

  local total = 0
  local seen, tags = {}, {}
  for _, column in ipairs(board.columns) do
    total = total + #column.cards
    for _, card in ipairs(column.cards) do
      for _, tag in ipairs(board_mod.tags(card.note:frontmatter())) do
        if not seen[tag] then
          seen[tag] = true
          table.insert(tags, tag)
        end
      end
    end
  end

  -- The title line: board name, card count, tag legend and the help hint.
  local marks = {}
  local title = {
    { " ", nil },
    { board.name, "BaseBoardTitle" },
    { ("   %d cards"):format(total), "BaseBoardMuted" },
    { "   ", nil },
  }
  for _, tag in ipairs(tags) do
    table.insert(title, { " " .. tag .. " ", tag_group(board_mod.tag_color(board, tag)) })
    table.insert(title, { " ", nil })
  end
  table.insert(title, { "  ? keys", "BaseBoardMuted" })

  local function emit(row, segments)
    local parts, byte = {}, 0
    local offsets = {}
    for _, seg in ipairs(segments) do
      if seg.column then
        offsets[seg.column] = byte
      end
      if seg[2] then
        table.insert(marks, {
          row = row,
          start = byte,
          stop = byte + #seg[1],
          hl = seg[2],
          sel_hl = seg[3] or seg[2],
          card = seg.card,
        })
      end
      table.insert(parts, seg[1])
      byte = byte + #seg[1]
    end
    return table.concat(parts), offsets
  end

  local lines = { (emit(0, title)), "" }
  state.offsets = {}
  for row = 1, height do
    local segments = {}
    for i, column in ipairs(columns) do
      local first = true
      for _, seg in ipairs(column[row] or { { (" "):rep(WIDTH) } }) do
        if first then
          seg.column = i
          first = false
        end
        table.insert(segments, seg)
      end
      if i < #columns then
        table.insert(segments, { GAP })
      end
    end
    local line, offsets = emit(TOP + row - 1, segments)
    state.offsets[TOP + row] = offsets
    table.insert(lines, line)
  end
  state.marks = marks

  local buf = state.buf
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
  paint(state, nil)
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

-- Repaints when the card under the cursor changed.
local function track_selection(state)
  local ci, k = selection(state)
  local card = k and state.board.columns[ci].cards[k]
  if card ~= state.painted then
    paint(state, card)
  end
end

-- Places the cursor on a card's title (or the header of an empty column) and
-- scrolls horizontally so the whole column is visible.
local function focus(state, ci, k)
  local card = k and state.board.columns[ci].cards[k]
  local row = card and card_row(card, "title_line") or HEADER_ROW
  local col = state.offsets[row][ci] + (card and 2 or 1)
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
  track_selection(state)
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

local augroup = vim.api.nvim_create_augroup("base-board-view", {})

-- Board state by buffer, for repainting on a colorscheme change.
local boards = {}

vim.api.nvim_create_autocmd("ColorScheme", {
  group = augroup,
  callback = function()
    for buf, state in pairs(boards) do
      if vim.api.nvim_buf_is_valid(buf) then
        local selected = state.painted
        render(state)
        paint(state, selected)
      else
        boards[buf] = nil
      end
    end
  end,
})

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

  vim.api.nvim_clear_autocmds({ group = augroup, buffer = buf })
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = augroup,
    buffer = buf,
    callback = function()
      track_selection(state)
    end,
  })
  boards[buf] = state
  -- Notes may have changed while the board was hidden.
  vim.api.nvim_create_autocmd("BufLeave", {
    group = augroup,
    buffer = buf,
    callback = function()
      state.hidden = true
    end,
  })
  vim.api.nvim_create_autocmd("BufEnter", {
    group = augroup,
    buffer = buf,
    callback = function()
      if state.hidden then
        state.hidden = false
        reload(state)
      end
    end,
  })
end

--- Renders the board into `buf`, named `base-board://<path to .base>`. Runs
--- whenever Neovim reads such a buffer: from M.open, `:edit` or a restored
--- session.
---@param buf integer
function M.load(buf)
  local base_path = vim.api.nvim_buf_get_name(buf):sub(#M.PREFIX + 1)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "base-board"
  local state = { buf = buf, board = board_mod.load(base_path) }
  render(state)
  for option, value in pairs({
    wrap = false,
    number = false,
    relativenumber = false,
    signcolumn = "no",
    list = false,
    cursorline = false,
    spell = false,
    sidescrolloff = 0,
    fillchars = "eob: ",
  }) do
    vim.wo[0][0][option] = value
  end
  attach(state)
  focus_path(state, nil, 1)
end

--- Opens (or switches to) the board for a `.base` file in the current window.
---@param base_path string
function M.open(base_path)
  vim.cmd.edit(vim.fn.fnameescape(M.PREFIX .. base_path))
end

return M
