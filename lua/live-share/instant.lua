local M = {}

function M.setup(config)
    M.config = config
end

function M.start(port)
    port = port or M.config.port_internal

    vim.cmd('InstantStartServer 0.0.0.0 ' .. port)
    vim.cmd('InstantStartSession 0.0.0.0 ' .. port)
end

function M.join(url, port)
    url = url:gsub("^https?://", "")
    port = port or M.config.port
    vim.cmd('InstantJoinSession ' .. url .. ' ' .. port)
end

return M

