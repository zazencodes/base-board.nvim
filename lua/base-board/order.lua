-- Card order values, compatible with the Obsidian Base Board plugin.
--
-- Base Board stores each card's position in the `kanban_order` frontmatter
-- property. Current values are fractional-indexing keys (rocicorp's
-- fractional-indexing, base 62 for both the digits and the integer head);
-- older values are numbers. This is a port of the parts Base Board uses, so
-- both editors generate the same keys.

local M = {}

M.PROPERTY = "kanban_order"

local DIGITS = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
local ZERO = "0"
local LAST = "z"
local HALF = #DIGITS / 2

local INDEX = {}
for i = 1, #DIGITS do
  INDEX[DIGITS:sub(i, i)] = i - 1
end

local function digit(i)
  return DIGITS:sub(i + 1, i + 1)
end

-- Byte-wise comparison, matching JavaScript string comparison for ASCII.
-- Lua's `<` on strings follows the locale's collation.
local function less(a, b)
  for i = 1, math.min(#a, #b) do
    local x, y = a:byte(i), b:byte(i)
    if x ~= y then
      return x < y
    end
  end
  return #a < #b
end

local function midpoint(a, b)
  if b and not less(a, b) then
    error(a .. " >= " .. b)
  end
  if a:sub(-1) == ZERO or (b and b:sub(-1) == ZERO) then
    error("trailing zero")
  end
  if b then
    local n = 0
    while (a:sub(n + 1, n + 1) ~= "" and a:sub(n + 1, n + 1) or ZERO) == b:sub(n + 1, n + 1) do
      n = n + 1
    end
    if n > 0 then
      return b:sub(1, n) .. midpoint(a:sub(n + 1), b:sub(n + 1))
    end
  end
  local digit_a = a ~= "" and INDEX[a:sub(1, 1)] or 0
  local digit_b = b and INDEX[b:sub(1, 1)] or #DIGITS
  if digit_b - digit_a > 1 then
    return digit(math.floor(0.5 * (digit_a + digit_b) + 0.5))
  end
  if b and #b > 1 then
    return b:sub(1, 1)
  end
  return digit(digit_a) .. midpoint(a:sub(2), nil)
end

local function integer_length(head)
  local i = INDEX[head]
  if not i then
    error("invalid order key head: " .. head)
  end
  return i < HALF and HALF - i + 1 or i - HALF + 2
end

local function integer_part(key)
  local length = integer_length(key:sub(1, 1))
  if length > #key then
    error("invalid order key: " .. key)
  end
  return key:sub(1, length)
end

local function validate_integer(int)
  if #int ~= integer_length(int:sub(1, 1)) then
    error("invalid integer part of order key: " .. int)
  end
end

local function validate_key(key)
  if key == digit(0) .. ZERO:rep(HALF) then
    error("invalid order key: " .. key)
  end
  for i = 1, #key do
    if not INDEX[key:sub(i, i)] then
      error("invalid order key: " .. key)
    end
  end
  local fraction = key:sub(#integer_part(key) + 1)
  if fraction:sub(-1) == ZERO then
    error("invalid order key: " .. key)
  end
end

local function step_integer(x, delta)
  validate_integer(x)
  local head = x:sub(1, 1)
  local wrap = delta > 0 and ZERO or LAST
  local trailing = ""
  for i = #x, 2, -1 do
    local d = INDEX[x:sub(i, i)] + delta
    if d == #DIGITS or d == -1 then
      trailing = wrap .. trailing
    else
      return head .. x:sub(2, i - 1) .. digit(d) .. trailing
    end
  end
  local head_index = INDEX[head] + delta
  if head_index == #DIGITS or head_index == -1 then
    return nil
  end
  local h = digit(head_index)
  local length_delta = integer_length(h) - integer_length(head)
  if length_delta > 0 then
    return h .. trailing .. wrap
  elseif length_delta < 0 then
    return h .. trailing:sub(2)
  end
  return h .. trailing
end

---@param a string|nil
---@param b string|nil
---@return string
function M.key_between(a, b)
  if a then
    validate_key(a)
  end
  if b then
    validate_key(b)
  end
  if a and b and less(b, a) then
    a, b = b, a
  end
  if not a then
    if not b then
      return digit(HALF) .. ZERO
    end
    local ib = integer_part(b)
    local fb = b:sub(#ib + 1)
    if ib == digit(0) .. ZERO:rep(HALF) then
      return ib .. midpoint("", fb)
    end
    if less(ib, b) then
      return ib
    end
    return step_integer(ib, -1) or error("cannot decrement any more")
  end
  if not b then
    local ia = integer_part(a)
    local fa = a:sub(#ia + 1)
    return step_integer(ia, 1) or ia .. midpoint(fa, nil)
  end
  local ia = integer_part(a)
  local fa = a:sub(#ia + 1)
  local ib = integer_part(b)
  local fb = b:sub(#ib + 1)
  if ia == ib then
    return ia .. midpoint(fa, fb)
  end
  local i = step_integer(ia, 1) or error("cannot increment any more")
  if less(i, b) then
    return i
  end
  return ia .. midpoint(fa, nil)
end

---@param a string|nil
---@param b string|nil
---@param n integer
---@return string[]
function M.keys_between(a, b, n)
  if n == 0 then
    return {}
  end
  if n == 1 then
    return { M.key_between(a, b) }
  end
  if not b then
    local c = M.key_between(a, b)
    local result = { c }
    for _ = 1, n - 1 do
      c = M.key_between(c, b)
      table.insert(result, c)
    end
    return result
  end
  if not a then
    local c = M.key_between(a, b)
    local result = { c }
    for _ = 1, n - 1 do
      c = M.key_between(a, c)
      table.insert(result, 1, c)
    end
    return result
  end
  local mid = math.floor(n / 2)
  local c = M.key_between(a, b)
  local result = M.keys_between(a, c, mid)
  table.insert(result, c)
  vim.list_extend(result, M.keys_between(c, b, n - mid - 1))
  return result
end

--- Whether `value` is a fractional-indexing key (not a legacy number).
function M.is_key(value)
  return type(value) == "string" and (pcall(M.key_between, value, nil))
end

--- Normalises a frontmatter value to an order value, or nil.
function M.read(value)
  if type(value) == "string" and value ~= "" then
    return value
  end
  if type(value) == "number" then
    return value
  end
  return nil
end

--- Sort comparison: numbers before keys, keys byte-wise, missing values last.
--- Returns -1, 0 or 1.
function M.compare(a, b)
  if a == b then
    return 0
  end
  if a == nil then
    return 1
  end
  if b == nil then
    return -1
  end
  if type(a) == "number" and type(b) == "number" then
    return a < b and -1 or 1
  end
  if type(a) == "string" and type(b) == "string" then
    return less(a, b) and -1 or 1
  end
  return type(a) == "number" and -1 or 1
end

M.less = less

return M
