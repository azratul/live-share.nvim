local M = {}

local services = {
  ["serveo.net"] = {
    command = function(cfg, port_internal, service_url)
      return string.format(
        "ssh -o StrictHostKeyChecking=no -R %d:localhost:%d %s > %s 2>/dev/null",
        cfg.port,
        port_internal,
        cfg.service,
        service_url
      )
    end,
    pattern = "https://[%w._-]+",
  },
  ["localhost.run"] = {
    command = function(cfg, port_internal, service_url)
      return string.format(
        "ssh -o StrictHostKeyChecking=no -R %d:localhost:%d %s > %s 2>/dev/null",
        cfg.port,
        port_internal,
        cfg.service,
        service_url
      )
    end,
    pattern = "https://[%w._-]+.lhr.life",
  },
  ["ngrok"] = {
    command = function(cfg, port_internal, service_url)
      return string.format("ngrok tcp %d --log stdout > %s 2>/dev/null", port_internal, service_url)
    end,
    pattern = "tcp://[%w._-]+%.ngrok.io:%d+",
  },
}

function M.setup(config)
  M.config = config

  vim.api.nvim_create_autocmd("VimLeavePre", {
    callback = function()
      if M.config.ssh_pid then
        vim.fn.jobstop(M.config.ssh_pid)
      end
    end,
  })
end

function M.start(port)
  local service = M.config.service
  local sconfig = services[service]

  if not sconfig then
    vim.api.nvim_err_writeln("Unsupported service: " .. service)
    return
  end

  local service_url = M.config.service_url
  local port_internal = port or M.config.port_internal
  local is_win = package.config:sub(1, 1) == "\\"
  local command
  local job_opts

  if is_win then
    local service_file = io.open(service_url, "w")
    if not service_file then
      vim.api.nvim_err_writeln("Failed to create the service URL file")
      return
    end
    service_file:close()

    local raw_command = sconfig.command(M.config, port_internal, service_url)
    raw_command = raw_command:gsub(" > %S+%s*2>/dev/null", "")

    if M.config.service ~= "ngrok" then
      raw_command = raw_command:gsub("^ssh", "ssh -n")
    end

    command =
      string.format('( %s 2>/dev/null ) | while read line; do echo "$line" >> "%s"; done', raw_command, service_url)

    job_opts = { "bash", "-c", command }
  else
    command = sconfig.command(M.config, port_internal, service_url)
    job_opts = command
  end

  local job_id = vim.fn.jobstart(job_opts, { detach = true })
  if job_id <= 0 then
    vim.api.nvim_err_writeln("Failed to start tunnel")
    return
  end

  M.config.ssh_pid = job_id

  local max_attempts = M.config.max_attempts
  local attempt = 0
  local wait = 250
  local timer = vim.loop.new_timer()

  local function check_url()
    attempt = attempt + 1
    local file = io.open(service_url, "r")
    if file then
      local result = file:read("*a")
      file:close()
      if result and result ~= "" then
        local url = result:match(sconfig.pattern)
        if url then
          local clipboard_ok = pcall(vim.fn.setreg, "+", url)
          if clipboard_ok then
            vim.api.nvim_out_write("The URL has been copied to the clipboard\n")
          else
            vim.api.nvim_err_writeln("Failed to copy URL to the clipboard")
          end

          timer:stop()
          timer:close()
        end
      elseif attempt >= max_attempts then
        vim.api.nvim_err_writeln("Service URL: empty file")
        timer:stop()
        timer:close()
      end
    elseif attempt >= max_attempts then
      vim.api.nvim_err_writeln("Service URL: file not found")
      timer:stop()
      timer:close()
    end
  end

  timer:start(wait, wait, vim.schedule_wrap(check_url))
end

return M
