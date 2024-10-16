local M = {}

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
    local service_url = M.config.service_url
    local service = M.config.service
    local port_internal = port or M.config.port_internal

    local is_win = package.config:sub(1, 1) == "\\"

    local command
    local job_opts

    if is_win then
        local service_file = io.open(service_url, "w")
        if service_file then
            service_file:close()
        else
            vim.api.nvim_err_writeln("Failed to create the service URL file")
            return
        end

        command = string.format(
            'bash -c (ssh -n -o StrictHostKeyChecking=no -R %d:localhost:%d %s 2>/dev/null) | while read line; do echo "$line" >> "%s"; done',
            M.config.port,
            port_internal,
            service,
            service_url
        )

        job_opts = {'bash', '-c', command}
    else
        command = string.format(
            "ssh -o StrictHostKeyChecking=no -R %d:localhost:%d %s > %s 2>/dev/null",
            M.config.port,
            port_internal,
            service,
            service_url
        )

        job_opts = command
    end

    local job_id = vim.fn.jobstart(job_opts, {detach = true})

    if job_id <= 0 then
        vim.api.nvim_err_writeln("Failed to start the SSH tunnel")
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
                local url
                if service == "localhost.run" or service == "nokey@localhost.run" then
                    url = result:match("https://[%w._-]+.lhr.life")
                else
                    url = result:match("https://[%w._-]+")
                end
                if url then
                    local clipboard_ok = pcall(vim.fn.setreg, "+", url)
                    if clipboard_ok then
                        vim.api.nvim_out_write("The URL has been copied to the clipboard\n")
                    else
                        vim.api.nvim_err_writeln("Failed to copy URL to the clipboard")
                    end
                    timer:stop()
                    timer:close()
                else
                    vim.api.nvim_err_writeln("Could not extract the URL from the file")
                end
            else
                if attempt >= max_attempts then
                    vim.api.nvim_err_writeln("Service URL: Empty file")
                    timer:stop()
                    timer:close()
                end
            end
        else
            if attempt >= max_attempts then
                vim.api.nvim_err_writeln("Service URL: file not found")
                timer:stop()
                timer:close()
            end
        end
    end

    timer:start(wait, wait, vim.schedule_wrap(check_url))
end

return M
