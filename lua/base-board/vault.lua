-- Vault access: finding notes, reading frontmatter, and writing single
-- frontmatter properties back without touching the rest of the file.

local yaml = require("base-board.yaml")

local M = {}

---@param path string  any file inside the vault
---@return string  absolute vault root (the directory holding `.obsidian`)
function M.root(path)
  local marker = vim.fs.find(".obsidian", { path = vim.fs.dirname(path), upward = true, type = "directory" })[1]
  if not marker then
    error("base-board: no .obsidian folder above " .. path, 0)
  end
  return vim.fs.dirname(marker)
end

-- Returns the frontmatter lines (without the `---` fences), or nil if the
-- file has no frontmatter.
local function read_frontmatter_lines(path)
  local file = assert(io.open(path, "r"))
  local first = file:read("*l")
  if first ~= "---" then
    file:close()
    return nil
  end
  local lines = {}
  for line in file:lines() do
    if line == "---" then
      file:close()
      return lines
    end
    table.insert(lines, line)
  end
  file:close()
  error("base-board: unterminated frontmatter in " .. path, 0)
end

local Note = {}
Note.__index = Note

function Note:frontmatter()
  if not self._frontmatter then
    local lines = read_frontmatter_lines(self.path)
    local ok, result = pcall(yaml.parse, table.concat(lines or {}, "\n"))
    if not ok then
      error(("%s (in %s)"):format(result, self.rel), 0)
    end
    self._frontmatter = result
  end
  return self._frontmatter
end

local function new_note(root, rel)
  local folder = vim.fs.dirname(rel)
  return setmetatable({
    path = root .. "/" .. rel,
    rel = rel,
    name = vim.fs.basename(rel):gsub("%.md$", ""),
    ext = "md",
    folder = folder == "." and "" or folder,
  }, Note)
end

---@param root string
---@param folder string  vault-relative folder to scan, "" for the whole vault
---@return table[]  every markdown note in `folder`, skipping dot folders
function M.notes(root, folder)
  local notes = {}
  local dir = folder == "" and root or (root .. "/" .. folder)
  if not vim.uv.fs_stat(dir) then
    return notes
  end
  local prefix = folder == "" and "" or (folder .. "/")
  for rel, kind in vim.fs.dir(dir, {
    depth = math.huge,
    skip = function(name)
      return name:sub(1, 1) ~= "."
    end,
  }) do
    if kind == "file" and rel:match("%.md$") then
      table.insert(notes, new_note(root, prefix .. rel))
    end
  end
  return notes
end

local PLAIN = "^[%w][%w ._/-]*$"
local KEYWORDS = { ["true"] = true, ["false"] = true, ["null"] = true, ["~"] = true }

local function format_value(value)
  if type(value) == "number" then
    return value == math.floor(value) and ("%d"):format(value) or tostring(value)
  end
  if type(value) ~= "string" then
    error("base-board: cannot write frontmatter value " .. vim.inspect(value), 0)
  end
  if value:match(PLAIN) and not value:match("%s$") and not KEYWORDS[value] and not tonumber(value) then
    return value
  end
  return '"' .. value:gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
end

--- Sets top-level frontmatter properties in a note. A value of `vim.NIL`
--- removes the property.
---@param path string
---@param props table<string, any>
function M.set_properties(path, props)
  local bufnr = vim.fn.bufnr(path)
  if bufnr ~= -1 and vim.bo[bufnr].modified then
    error("base-board: " .. path .. " has unsaved changes", 0)
  end
  local lines = vim.fn.readfile(path)
  local close
  if lines[1] == "---" then
    for i = 2, #lines do
      if lines[i] == "---" then
        close = i
        break
      end
    end
    if not close then
      error("base-board: unterminated frontmatter in " .. path, 0)
    end
  else
    table.insert(lines, 1, "---")
    table.insert(lines, 2, "---")
    close = 2
  end
  for key, value in pairs(props) do
    local found
    for i = 2, close - 1 do
      if lines[i]:match("^" .. vim.pesc(key) .. ":") then
        found = i
        break
      end
    end
    if found and lines[found + 1] and found + 1 < close and lines[found + 1]:match("^[%s%-]") then
      error(("base-board: %s in %s is a nested value; edit it by hand"):format(key, path), 0)
    end
    if value == vim.NIL then
      if found then
        table.remove(lines, found)
        close = close - 1
      end
    elseif found then
      lines[found] = key .. ": " .. format_value(value)
    else
      table.insert(lines, close, key .. ": " .. format_value(value))
      close = close + 1
    end
  end
  vim.fn.writefile(lines, path)
  if bufnr ~= -1 then
    vim.cmd.checktime(bufnr)
  end
end

return M
