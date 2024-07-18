local M = {}

function M.setup(config)
    M.config = config

    vim.api.nvim_create_autocmd("VimLeavePre", {
        callback = function()
            if M.config.ssh_pid then
                os.execute("kill -9 " .. M.config.ssh_pid)
            end
        end
    })
end

function M.start(port)
    local serveo_url = M.config.serveo_url
    local serveo_pid = M.config.serveo_pid
    local port_internal = port or M.config.port_internal
    local ssh_command = string.format("ssh -o StrictHostKeyChecking=no -R %d:localhost:%d serveo.net > %s 2>/dev/null & echo $! > %s", M.config.port, port_internal, serveo_url, serveo_pid)
    os.execute(ssh_command)
    local handle = io.popen("cat " .. serveo_pid)
    local result = handle:read("*a")
    handle:close()
    M.config.ssh_pid = result:match("%d+")

    local max_attempts = M.config.max_attempts
    local attempt = 0
    local wait = 250

    local function check_url()
      attempt = attempt + 1
      local file = io.open(serveo_url, "r")
      if file then
        local result = file:read("*a")
        file:close()
        if result and result ~= "" then
          local url = result:match("https://[%w._-]+")
          vim.fn.setreg('+', url)
          vim.api.nvim_out_write("The URL has been copied to the clipboard\n")
        else
          if attempt < max_attempts then
            vim.defer_fn(check_url, wait)
          else
            vim.api.nvim_err_writeln("Failed to start the tunnel")
          end
        end
      else
        vim.api.nvim_err_writeln("Error opening the temporary output file")
      end
    end

    vim.defer_fn(check_url, wait)
end

return M
