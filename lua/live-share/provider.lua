local M = {}
M.services = {}

function M.register(name, spec) M.services[name] = spec end
return M
