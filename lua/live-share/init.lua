local M = {}

function M.setup(config)
    config = config or {}
    M.config = {
        port = config.port or 80,
        port_internal = config.port_internal or 9876,
        max_attempts = config.max_attempts or 40,
        serveo_url = config.serveo_url or "/tmp/serveo.url",
        serveo_pid = config.serveo_pid or "/tmp/serveo.pid",
        ssh_pid = nil
    }

    require('live-share.instant').setup(M.config)
    require('live-share.tunnel').setup(M.config)
    require('live-share.commands').setup(M.config)
end

return M
