local M = {}

local SSH_SERVICES = {
  ["serveo.net"] = true,
  ["localhost.run"] = true,
  ["nokey@localhost.run"] = true,
}

local function openssl_install_hint()
  if vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1 then
    return "install Win32 OpenSSL (slproweb.com) or set openssl_lib to the libcrypto DLL path"
  elseif vim.fn.has("mac") == 1 then
    return "run: brew install openssl  — or set openssl_lib to the libcrypto path in live-share.setup()"
  else
    return "run: apt install libssl-dev  (or pacman -S openssl / dnf install openssl-devel)  "
      .. "— NixOS users: set openssl_lib to the full libcrypto.so path in live-share.setup()"
  end
end

function M.check()
  vim.health.start("live-share.nvim — core requirements")

  -- Neovim version
  if vim.fn.has("nvim-0.9") == 1 then
    vim.health.ok("Neovim 0.9+ found")
  else
    vim.health.error("Neovim 0.9+ is required")
  end

  -- vim.uv / vim.loop (TCP transport)
  if vim.uv or vim.loop then
    vim.health.ok("vim.loop (libuv) available")
  else
    vim.health.error("vim.loop not found — TCP transport will not work")
  end

  -- LuaJIT FFI (needed for AES-GCM)
  local ffi_ok = pcall(require, "ffi")
  if ffi_ok then
    vim.health.ok("LuaJIT FFI available")
  else
    vim.health.error("LuaJIT FFI not available — install a LuaJIT-based Neovim build; AES-256-GCM is required")
  end

  -- OpenSSL libcrypto (AES-GCM)
  local crypto = require("live-share.collab.crypto")
  if crypto.available then
    vim.health.ok("OpenSSL libcrypto found — AES-256-GCM encryption enabled")
  else
    vim.health.error("OpenSSL libcrypto not found — encryption is required; " .. openssl_install_hint())
  end

  -- ── Configuration ────────────────────────────────────────────────────────────
  vim.health.start("live-share.nvim — configuration")

  local cfg = require("live-share").get_config()

  if not cfg then
    vim.health.warn("live-share.setup() has not been called — configuration checks skipped")
    return
  end

  -- Username
  local username = cfg.username or vim.g.live_share_username
  if username and username ~= "" then
    vim.health.ok("username: " .. username)
  else
    vim.health.warn(
      "no username configured — peers will see you as 'unknown'; add username = \"your-name\" to live-share.setup()"
    )
  end

  -- Transport mode
  local transport = cfg.transport or "ws"

  if transport == "punch" then
    vim.health.ok("transport: punch (P2P UDP via NAT hole-punching)")

    local punch_ok = pcall(require, "punch")
    if punch_ok then
      vim.health.ok("punch library found — P2P transport available")
    else
      vim.health.error('punch library not found — required for transport = "punch"; run: luarocks install punch')
    end

    local stun = cfg.stun or "stun.l.google.com:19302"
    local stun_str = type(stun) == "table" and table.concat(stun, ", ") or stun
    vim.health.ok("STUN servers: " .. stun_str)
  else
    vim.health.ok("transport: ws (WebSocket / raw TCP)")
  end

  -- Tunnel provider binary
  local service = cfg.service or "nokey@localhost.run"

  if SSH_SERVICES[service] then
    if vim.fn.executable("ssh") == 1 then
      vim.health.ok("'ssh' found — required for tunnel provider '" .. service .. "'")
    else
      vim.health.error("'ssh' not found — required for tunnel provider '" .. service .. "'; install OpenSSH")
    end
  elseif service == "ngrok" then
    if vim.fn.executable("ngrok") == 1 then
      vim.health.ok("'ngrok' CLI found")
    else
      vim.health.error(
        "'ngrok' CLI not found — required for tunnel provider 'ngrok'; "
          .. "download from ngrok.com and authenticate with: ngrok config add-authtoken <your_token>"
      )
    end
  elseif service == "bore" then
    if vim.fn.executable("bore") == 1 then
      vim.health.ok("'bore' CLI found")
    else
      vim.health.error("'bore' CLI not found — required for tunnel provider 'bore'; run: cargo install bore-cli")
    end
  else
    vim.health.warn(
      "tunnel provider '" .. service .. "' is a custom provider — verify its binary is in PATH manually"
    )
  end
end

return M
