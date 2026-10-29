if vim.g.loaded_base_board then
  return
end
vim.g.loaded_base_board = true

local PREFIX = require("base-board.view").PREFIX

-- Shows the `.base` file itself; it stays YAML until the board is toggled on.
local function show_yaml(base_path)
  local buf = vim.fn.bufadd(base_path)
  vim.b[buf].base_board_off = true
  vim.api.nvim_set_current_buf(buf)
end

local function show_board(base_path)
  local buf = vim.fn.bufnr(base_path)
  if buf ~= -1 then
    vim.b[buf].base_board_off = nil
  end
  require("base-board.view").open(base_path)
end

vim.api.nvim_create_user_command("BaseBoard", function(opts)
  local name = vim.api.nvim_buf_get_name(0)
  if opts.args == "" and vim.startswith(name, PREFIX) then
    show_yaml(name:sub(#PREFIX + 1))
    return
  end
  local path = opts.args ~= "" and opts.args or name
  path = vim.fs.abspath(vim.fn.expand(path))
  if not path:match("%.base$") then
    error("base-board: :BaseBoard needs a .base file (got " .. path .. ")", 0)
  end
  show_board(path)
end, { nargs = "?", complete = "file", desc = "Toggle the Base Board for a .base file" })

local group = vim.api.nvim_create_augroup("base-board", {})

-- Board buffers are rendered whenever Neovim reads them, so `:edit` and
-- restored sessions show the board.
vim.api.nvim_create_autocmd("BufReadCmd", {
  group = group,
  pattern = PREFIX .. "*",
  callback = function(args)
    require("base-board.view").load(args.buf)
  end,
})

-- Boards open in place of their `.base` file.
vim.api.nvim_create_autocmd("BufReadPost", {
  group = group,
  pattern = "*.base",
  nested = true, -- so the board buffer's BufReadCmd runs
  callback = function(args)
    local path = vim.api.nvim_buf_get_name(args.buf)
    if vim.b[args.buf].base_board_off or not require("base-board.board").is_board(path) then
      return
    end
    require("base-board.view").open(path)
  end,
})
