-- Parser for the block-style YAML subset that Obsidian writes in `.base`
-- files and note frontmatter: nested mappings and sequences, plain and quoted
-- scalars, and flow sequences of scalars. Anything else is an error.

local M = {}

local function fail(lnum, msg)
  error(("base-board: YAML line %d: %s"):format(lnum, msg), 0)
end

-- Removes a trailing comment, ignoring `#` inside quotes.
local function strip_comment(text)
  local quote
  for i = 1, #text do
    local ch = text:sub(i, i)
    if quote then
      if ch == quote then
        quote = nil
      end
    elseif ch == '"' or ch == "'" then
      quote = ch
    elseif ch == "#" and (i == 1 or text:sub(i - 1, i - 1):match("%s")) then
      return text:sub(1, i - 1)
    end
  end
  return text
end

local function scalar(text, lnum)
  if text == "" or text == "~" or text == "null" then
    return nil
  end
  if text == "true" then
    return true
  end
  if text == "false" then
    return false
  end
  local first = text:sub(1, 1)
  if first == "'" then
    if not text:match("^'.*'$") then
      fail(lnum, "unterminated single-quoted string")
    end
    return (text:sub(2, -2):gsub("''", "'"))
  end
  if first == '"' then
    if not text:match('^".*"$') then
      fail(lnum, "unterminated double-quoted string")
    end
    local escapes = { n = "\n", t = "\t", ['"'] = '"', ["\\"] = "\\" }
    return (text:sub(2, -2):gsub("\\(.)", function(ch)
      return escapes[ch] or fail(lnum, "unsupported escape \\" .. ch)
    end))
  end
  if first == "[" then
    if not text:match("^%[.*%]$") then
      fail(lnum, "unterminated flow sequence")
    end
    local items = {}
    local inner = vim.trim(text:sub(2, -2))
    if inner ~= "" then
      for item in (inner .. ","):gmatch("([^,]*),") do
        table.insert(items, scalar(vim.trim(item), lnum))
      end
    end
    return items
  end
  if first:match("[|>&*!{%%@`]") then
    fail(lnum, "unsupported YAML syntax: " .. text)
  end
  if text:match("^%-?%d+$") or text:match("^%-?%d+%.%d+$") then
    return tonumber(text)
  end
  return text
end

-- Splits `key: value` at the first `:` followed by a space or line end,
-- ignoring colons inside a quoted key.
local function split_pair(text, lnum)
  local key, rest
  local first = text:sub(1, 1)
  if first == '"' or first == "'" then
    local close = text:find(first, 2, true)
    if not close then
      fail(lnum, "unterminated quoted key")
    end
    key = scalar(text:sub(1, close), lnum)
    rest = text:sub(close + 1)
    if not rest:match("^:") then
      fail(lnum, "expected ':' after quoted key")
    end
    rest = rest:sub(2)
  else
    local colon = text:find(":%s") or (text:sub(-1) == ":" and #text)
    if not colon then
      return nil
    end
    key = vim.trim(text:sub(1, colon - 1))
    rest = text:sub(colon + 1)
  end
  return key, vim.trim(rest)
end

local function is_item(text)
  return text == "-" or text:sub(1, 2) == "- "
end

local parse_block

local function parse_sequence(lines, i, indent)
  local list = {}
  while lines[i] and lines[i].indent == indent and is_item(lines[i].text) do
    local line = lines[i]
    local item = vim.trim(line.text:sub(2))
    if item == "" then
      if not lines[i + 1] or lines[i + 1].indent <= indent then
        fail(line.lnum, "empty sequence item")
      end
      local value
      value, i = parse_block(lines, i + 1, lines[i + 1].indent)
      table.insert(list, value)
    elseif not item:match("^[\"'%[]") and split_pair(item, line.lnum) then
      -- A mapping that starts on the item line: re-read the line as a
      -- mapping key at the column where the item text starts.
      local column = indent + 1 + #line.text:sub(2):match("^ *")
      lines[i] = { indent = column, text = item, lnum = line.lnum }
      local value
      value, i = parse_block(lines, i, column)
      table.insert(list, value)
    else
      table.insert(list, scalar(item, line.lnum))
      i = i + 1
    end
  end
  return list, i
end

local function parse_mapping(lines, i, indent)
  local map = {}
  while lines[i] and lines[i].indent == indent and not is_item(lines[i].text) do
    local line = lines[i]
    local key, rest = split_pair(line.text, line.lnum)
    if not key then
      fail(line.lnum, "expected 'key: value'")
    end
    i = i + 1
    if rest ~= "" then
      map[key] = scalar(rest, line.lnum)
    elseif lines[i] and (lines[i].indent > indent or (lines[i].indent == indent and is_item(lines[i].text))) then
      map[key], i = parse_block(lines, i, lines[i].indent)
    end
  end
  return map, i
end

parse_block = function(lines, i, indent)
  if is_item(lines[i].text) then
    return parse_sequence(lines, i, indent)
  end
  return parse_mapping(lines, i, indent)
end

---@param text string
---@return table
function M.parse(text)
  local lines = {}
  local lnum = 0
  for raw in (text .. "\n"):gmatch("(.-)\r?\n") do
    lnum = lnum + 1
    if raw:match("^%s*\t") then
      fail(lnum, "tab indentation")
    end
    local content = strip_comment(raw)
    if content:match("%S") then
      local indent = #content:match("^ *")
      table.insert(lines, { indent = indent, text = vim.trim(content), lnum = lnum })
    end
  end
  if #lines == 0 then
    return {}
  end
  local value, i = parse_block(lines, 1, lines[1].indent)
  if lines[i] then
    fail(lines[i].lnum, "unexpected indentation")
  end
  return value
end

return M
