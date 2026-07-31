local M = {}

local provider = require("live-share.provider")
local services = provider.services

local ssh_command = function(cfg, port_internal, service_url)
  return string.format(
    "ssh -o StrictHostKeyChecking=no -R %d:localhost:%d %s > %s 2>/dev/null",
    cfg.port,
    port_internal,
    cfg.service,
    service_url
  )
end

provider.register("serveo.net", {
  command = ssh_command,
  pattern = "https://[%w._-]+",
})

provider.register("localhost.run", {
  command = ssh_command,
  pattern = "https://[%w._-]+.lhr.life",
})

provider.register("nokey@localhost.run", {
  command = ssh_command,
  pattern = "https://[%w._-]+.lhr.life",
})

provider.register("ngrok", {
  command = function(_, port_internal, service_url)
    return string.format("ngrok tcp %d --log stdout > %s 2>/dev/null", port_internal, service_url)
  end,
  pattern = "tcp://[%w._-]+%.ngrok.io:%d+",
})

-- First line with visible content, used to quote the provider's own error back
-- to the user instead of a bare exit code.
local function first_line(text)
  for line in (text or ""):gmatch("[^\r\n]+") do
    if line:match("%S") then
      return line
    end
  end
  return nil
end

local function read_service_url(path)
  local file = io.open(path, "r")
  if not file then
    return nil
  end
  local content = file:read("*a")
  file:close()
  return content
end

function M.setup(config)
  M.config = config

  vim.api.nvim_create_autocmd("VimLeavePre", {
    callback = function()
      M.stop()
    end,
  })
end

-- start(port [, opts])
--   port           — internal port to expose
--   opts.url_prefix — string prepended to the public URL before the key fragment
--                     (e.g. "punch+" for punch transport)
function M.start(port, opts)
  opts = opts or {}
  local url_prefix = opts.url_prefix or ""
  local service = M.config.service
  local sconfig = services[service]

  if not sconfig then
    vim.api.nvim_err_writeln("Unsupported service: " .. tostring(service))
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

  local max_attempts = M.config.max_attempts
  local attempt = 0
  local wait = 250
  local timer = vim.loop.new_timer()
  local job_id
  local done = false

  -- Single exit path for the poll timer, so the process-exit handler and the
  -- retry budget cannot both report on the same start().
  local function finish()
    if done then
      return
    end
    done = true
    timer:stop()
    if not timer:is_closing() then
      timer:close()
    end
  end

  local function fail(reason)
    if done then
      return
    end
    finish()
    vim.api.nvim_err_writeln(("live-share: tunnel '%s' failed — %s"):format(service, reason))
  end

  -- A tunnel that died never established anything, so there is no URL to fall
  -- back on: whatever it left in the file is its own error output.  Report the
  -- failure and quote the provider's message rather than scraping it.
  local function fail_exited(code, output)
    local head = first_line(output or read_service_url(service_url))
    fail(("exited with code %d before publishing a URL%s"):format(code, head and (": " .. head) or ""))
  end

  job_id = vim.fn.jobstart(job_opts, {
    detach = true,
    on_exit = function(id, code)
      -- M.stop() clears ssh_pid before killing the job; that exit is expected.
      if done or M.config.ssh_pid ~= id then
        return
      end
      if code ~= 0 then
        fail_exited(code)
      end
    end,
  })
  if job_id <= 0 then
    finish()
    vim.api.nvim_err_writeln("Failed to start tunnel")
    return
  end

  M.config.ssh_pid = job_id

  local function check_url()
    if done then
      return
    end
    attempt = attempt + 1

    local result = read_service_url(service_url)
    if result and result ~= "" then
      local url = result:match(sconfig.pattern)
      if url then
        -- The pattern matched, but a provider that has already exited with an
        -- error never announced anything — the match came from its error
        -- output.  (bore prints "could not connect to bore.pub:7835", its
        -- control port, which satisfies a naive "bore%.pub:%d+".)  jobwait
        -- with a 0 timeout returns the exit code, or a negative value while
        -- the process is still running.
        local status = vim.fn.jobwait({ job_id }, 0)[1]
        if status > 0 then
          fail_exited(status, result)
          return
        end

        -- Prepend transport prefix (e.g. "punch+") and append encryption key fragment.
        local ok_host, h = pcall(require, "live-share.host")
        local key_frag = (ok_host and h.get_key_fragment()) or ""
        url = url_prefix .. url .. key_frag
        M.last_url = url

        finish()

        if vim.fn.has("clipboard") == 1 then
          local clipboard_ok = pcall(vim.fn.setreg, "+", url)
          if clipboard_ok then
            vim.api.nvim_out_write("The URL has been copied to the clipboard\n")
          else
            vim.api.nvim_err_writeln("Failed to copy URL to the clipboard")
          end
        else
          vim.api.nvim_out_write("Clipboard not available. URL: " .. url .. "\n")
        end
        return
      end
    end

    -- Every branch has to be able to give up.  Previously max_attempts was only
    -- consulted for a missing or empty file, so output that never matched the
    -- pattern left this timer polling every 250 ms for the rest of the session
    -- without ever reporting anything.
    if attempt >= max_attempts then
      if result == nil then
        fail("service URL file not found: " .. service_url)
      elseif result == "" then
        fail("no URL published within " .. tostring(max_attempts * wait / 1000) .. "s (no output)")
      else
        local head = first_line(result)
        fail(("output did not contain a share URL%s"):format(head and (": " .. head) or ""))
      end
    end
  end

  timer:start(wait, wait, vim.schedule_wrap(check_url))
end

function M.stop()
  if M.config and M.config.ssh_pid then
    -- Cleared first: the on_exit handler installed by start() compares against
    -- ssh_pid so it stays quiet for a tunnel we killed on purpose.
    local job_id = M.config.ssh_pid
    M.config.ssh_pid = nil
    vim.fn.jobstop(job_id)
  end
  M.last_url = nil
end

return M
