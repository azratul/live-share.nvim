local M = {}

function M.setup(config)
    config = config or {}
    M.config = {
        port = config.port or 80,
        port_internal = config.port_internal or 9876,
        max_attempts = config.max_attempts or 40,
        service_url = config.service_url or "/tmp/service.url",
        service_pid = config.service_pid or "/tmp/service.pid",
        service = config.service or "localhost.run",
        ssh_pid = nil
    }

    require('live-share.instant').setup(M.config)
    require('live-share.tunnel').setup(M.config)
    require('live-share.commands').setup(M.config)
end

return M
