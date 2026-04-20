vim.opt.runtimepath:prepend(".")
vim.opt.runtimepath:prepend(vim.fn.expand("~/.local/share/nvim/site/pack/vendor/start/plenary.nvim"))

require("plenary")
