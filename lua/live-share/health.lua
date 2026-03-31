local M = {}

function M.check()
  vim.health.start("live-share.nvim")

  -- Neovim version
  if vim.fn.has("nvim-0.5") == 1 then
    vim.health.ok("Neovim 0.5+ found")
  else
    vim.health.error("Neovim 0.5+ is required")
  end

  -- vim.loop / vim.uv (always present in Neovim, but verify)
  if vim.uv or vim.loop then
    vim.health.ok("vim.loop (libuv) available")
  else
    vim.health.error("vim.loop not found — TCP transport will not work")
  end

  -- LuaJIT FFI (needed for AES-GCM encryption)
  local ffi_ok = pcall(require, "ffi")
  if ffi_ok then
    vim.health.ok("LuaJIT FFI available")
  else
    vim.health.warn("LuaJIT FFI not available — sessions will run without encryption")
  end

  -- OpenSSL libcrypto (needed for AES-GCM encryption)
  local crypto = require("live-share.collab.crypto")
  if crypto.available then
    vim.health.ok("OpenSSL libcrypto found — AES-256-GCM encryption enabled")
  else
    vim.health.warn("OpenSSL libcrypto not found — sessions will run without encryption")
  end

  -- SSH (needed for tunnel providers: serveo.net, localhost.run)
  if vim.fn.executable("ssh") == 1 then
    vim.health.ok("'ssh' found (required for serveo.net / localhost.run providers)")
  else
    vim.health.warn("'ssh' not found — only the 'ngrok' provider will work")
  end
end

return M
