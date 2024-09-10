local M = {}

function M.setup(config)
	M.config = config

	vim.api.nvim_create_autocmd("VimLeavePre", {
		callback = function()
			if M.config.ssh_pid then
				os.execute("kill -9 " .. M.config.ssh_pid)
			end
		end,
	})
end

function M.start(port)
	local service_url = M.config.service_url
	local service_pid = M.config.service_pid
	local service = M.config.service
	local port_internal = port or M.config.port_internal
	local command = string.format(
		"ssh -o StrictHostKeyChecking=no -R %d:localhost:%d %s > %s 2>/dev/null & echo $! > %s",
		M.config.port,
		port_internal,
		service,
		service_url,
		service_pid
	)

	os.execute(command)
	local handle = io.popen("cat " .. service_pid)
	if not handle then
		vim.api.nvim_err_writeln("Error opening the temporary output file")
		return
	end
	local result = handle:read("*a")
	handle:close()
	M.config.ssh_pid = result:match("%d+")

	local max_attempts = M.config.max_attempts
	local attempt = 0
	local wait = 250

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
				vim.fn.setreg("+", url)
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
