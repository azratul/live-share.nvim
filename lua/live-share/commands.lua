local M = {}

function M.setup(config)
  M.config = config
end

function M.start_live_share(port)
  port = port or M.config.port_internal
  require("live-share.instant").start(port)
  require("live-share.tunnel").start(port)
end

function M.join_live_share(url, port)
  port = port or M.config.port
  require("live-share.instant").join(url, port)
end

return M
