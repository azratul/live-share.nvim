
local M = {}

function M.check()
    vim.health.start("live-share.nvim Health Check")

    if not vim.fn.has("nvim-0.5") == 1 then
        vim.health.error("Neovim 0.5+ is required for live-share.nvim.")
    else
        vim.health.ok("Correct Neovim version found.")
    end

    if vim.fn.executable("ssh") == 0 then
        vim.health.error("'ssh' command is not available in your PATH.")
    else
        vim.health.ok("'ssh' command is available.")
    end
end

return M
