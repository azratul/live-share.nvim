if vim.g.loaded_liveshare then
  return
end
vim.g.loaded_liveshare = true

local save_cpo = vim.o.cpo
vim.o.cpo = vim.o.cpo .. 'vim'

require('live-share').setup()

vim.api.nvim_create_user_command('LiveShareServer', function(opts)
  require("live-share.commands").start_live_share(tonumber(opts.args))
end, { nargs = '?' })

vim.api.nvim_create_user_command('LiveShareJoin', function(opts)
  local args = vim.split(opts.args, " ")
  local url = args[1]
  local port = tonumber(args[2])
  require("live-share.commands").join_live_share(url, port)
end, { nargs = '+' })

vim.o.cpo = save_cpo
