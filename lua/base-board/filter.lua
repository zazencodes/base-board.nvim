-- Evaluates Obsidian Bases filters against a note.
--
-- Supported: `and` / `or` / `not` groups, and expressions built from
--   file.inFolder("folder")   <property>.isEmpty()
--   <property> == <literal>   <property> != <literal>
--   !<expression>
-- where <property> is `file.name`, `file.ext`, `file.path`, `file.folder`,
-- `note.<key>` or a bare frontmatter `<key>`, and <literal> is a quoted
-- string, number, `true` or `false`. Anything else is an error, so a board
-- never silently shows a different set of cards than Obsidian.

local M = {}

local function fail(expr, msg)
  error(("base-board: unsupported filter %q: %s"):format(expr, msg), 0)
end

local function tokenize(expr)
  local tokens = {}
  local i = 1
  while i <= #expr do
    local ch = expr:sub(i, i)
    if ch:match("%s") then
      i = i + 1
    elseif ch == '"' or ch == "'" then
      local close = expr:find(ch, i + 1, true) or fail(expr, "unterminated string")
      table.insert(tokens, { kind = "literal", value = expr:sub(i + 1, close - 1) })
      i = close + 1
    elseif expr:sub(i, i + 1) == "==" or expr:sub(i, i + 1) == "!=" then
      table.insert(tokens, { kind = "op", value = expr:sub(i, i + 1) })
      i = i + 2
    elseif ch == "!" or ch == "(" or ch == ")" then
      table.insert(tokens, { kind = ch })
      i = i + 1
    elseif ch:match("[%d%-]") then
      local num = expr:match("^%-?%d+%.?%d*", i) or fail(expr, "bad number")
      table.insert(tokens, { kind = "literal", value = tonumber(num) })
      i = i + #num
    elseif ch:match("[%a_]") then
      local path = expr:match("^[%w_%.]+", i)
      local kind = "path"
      local value = path
      if path == "true" or path == "false" then
        kind, value = "literal", path == "true"
      end
      table.insert(tokens, { kind = kind, value = value })
      i = i + #path
    else
      fail(expr, "unexpected character " .. ch)
    end
  end
  return tokens
end

-- Resolves a property path for a note.
local function property(note, path, expr)
  local file_props = {
    ["file.name"] = note.name,
    ["file.ext"] = note.ext,
    ["file.path"] = note.rel,
    ["file.folder"] = note.folder,
  }
  if file_props[path] ~= nil then
    return file_props[path]
  end
  if path:match("^file%.") or path:match("^formula%.") then
    fail(expr, "unsupported property " .. path)
  end
  local key = path:gsub("^note%.", "")
  return note:frontmatter()[key]
end

local function is_empty(value)
  return value == nil or value == "" or (type(value) == "table" and #value == 0)
end

local function in_folder(note, folder)
  folder = folder:gsub("/$", "")
  return folder == "" or note.folder == folder or note.folder:sub(1, #folder + 1) == folder .. "/"
end

local function equals(value, literal, expr)
  if type(value) == "table" then
    fail(expr, "comparing a list property")
  end
  if value == nil then
    return false
  end
  if type(literal) == "number" then
    return tonumber(value) == literal
  end
  return value == literal
end

local function evaluate_string(expr, note)
  local tokens = tokenize(expr)
  local pos = 1

  local function peek(kind)
    return tokens[pos] and tokens[pos].kind == kind
  end

  local function expect(kind)
    if not peek(kind) then
      fail(expr, "expected " .. kind)
    end
    pos = pos + 1
    return tokens[pos - 1]
  end

  local function call_args()
    expect("(")
    local args = {}
    if not peek(")") then
      table.insert(args, expect("literal").value)
    end
    expect(")")
    return args
  end

  -- A property path, a function call on it, or a comparison.
  local function parse_term()
    local path = expect("path").value
    local method = path:match("%.(%w+)$")
    if peek("(") then
      local args = call_args()
      local target = path:sub(1, -#method - 2)
      if path == "file.inFolder" then
        return in_folder(note, args[1] or fail(expr, "inFolder needs a folder"))
      elseif method == "isEmpty" and #args == 0 then
        return is_empty(property(note, target, expr))
      end
      fail(expr, "unsupported function " .. path)
    end
    if peek("op") then
      local op = expect("op").value
      local result = equals(property(note, path, expr), expect("literal").value, expr)
      if op == "!=" then
        return not result
      end
      return result
    end
    fail(expr, "expected a comparison or function call")
  end

  local function parse_unary()
    if peek("!") then
      pos = pos + 1
      return not parse_unary()
    end
    return parse_term()
  end

  local result = parse_unary()
  if tokens[pos] then
    fail(expr, "unexpected trailing input")
  end
  return result
end

--- The folder every matching note must be in: a `file.inFolder(...)` the
--- filter requires through `and` groups alone, or nil if there is none.
---@param filter table|string|nil
---@return string|nil
function M.required_folder(filter)
  if type(filter) == "string" then
    local folder = filter:match([[^%s*file%.inFolder%(%s*"([^"]*)"%s*%)%s*$]])
      or filter:match([[^%s*file%.inFolder%(%s*'([^']*)'%s*%)%s*$]])
    return folder and (folder:gsub("/$", ""))
  end
  if type(filter) == "table" and filter["and"] then
    for _, child in ipairs(filter["and"]) do
      local folder = M.required_folder(child)
      if folder then
        return folder
      end
    end
  end
  return nil
end

---@param filter table|string|nil  a Bases filter (string or and/or/not group)
---@param note table  a vault note (see vault.lua)
---@return boolean
function M.matches(filter, note)
  if filter == nil then
    return true
  end
  if type(filter) == "string" then
    return evaluate_string(filter, note)
  end
  if type(filter) ~= "table" then
    fail(tostring(filter), "expected a string or a group")
  end
  local count = 0
  for key, children in pairs(filter) do
    count = count + 1
    if key == "and" then
      for _, child in ipairs(children) do
        if not M.matches(child, note) then
          return false
        end
      end
    elseif key == "or" then
      local any = false
      for _, child in ipairs(children) do
        if M.matches(child, note) then
          any = true
          break
        end
      end
      if not any then
        return false
      end
    elseif key == "not" then
      for _, child in ipairs(children) do
        if M.matches(child, note) then
          return false
        end
      end
    else
      fail(tostring(key), "unsupported filter group")
    end
  end
  if count ~= 1 then
    fail(vim.inspect(filter), "a filter group needs exactly one of and/or/not")
  end
  return true
end

return M
