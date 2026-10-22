if vim.g.loaded_base_board then
  return
end
vim.g.loaded_base_board = true

vim.api.nvim_create_user_command("BaseBoard", function(opts)
  local path = opts.args ~= "" and opts.args or vim.api.nvim_buf_get_name(0)
  path = vim.fs.abspath(vim.fn.expand(path))
  if not path:match("%.base$") then
    error("base-board: :BaseBoard needs a .base file (got " .. path .. ")", 0)
  end
  require("base-board.view").open(path)
end, { nargs = "?", complete = "file", desc = "Open the Base Board for a .base file" })
