-- Shared terminal: host spawns a PTY shell and broadcasts I/O to guests.
-- Guests receive a read-write terminal view whose keystrokes are forwarded back to the host.
--
-- Host side:
--   setup("host", broadcast_fn)
--   open_host()             — spawns shell, notifies guests
--   on_guest_input(id, data) — called when a guest sends keystrokes
--
-- Guest side:
--   setup("guest", send_fn)
--   open_guest(id, name)   — called on terminal_open message
--   on_data(id, data)      — called on terminal_data message
--   on_close(id)           — called on terminal_close message
local M = {}

local log = require("live-share.collab.log")
local scrollback = require("live-share.scrollback")
local uv = vim.uv or vim.loop

local DEFAULT_SCROLLBACK_BYTES = 65536

local function dbg(m)
  log.dbg("terminal", m)
end

-- terminals[term_id] = { chan, buf, job_id?, name?, scrollback? }
-- `name` and `scrollback` are host-only fields; the host uses them to replay
-- recent shell output to peers approved after the terminal was opened.
local terminals = {}
local next_id = 1
local role = nil -- "host" | "guest"
local send_fn = nil -- broadcasts (host) or sends to host (guest)
local scrollback_max = DEFAULT_SCROLLBACK_BYTES

function M.setup(r, fn, opts)
  role = r
  send_fn = fn
  opts = opts or {}
  if type(opts.scrollback_bytes) == "number" and opts.scrollback_bytes >= 0 then
    scrollback_max = opts.scrollback_bytes
  else
    scrollback_max = DEFAULT_SCROLLBACK_BYTES
  end
end

-- ── Host ─────────────────────────────────────────────────────────────────────

function M.open_host()
  local term_id = next_id
  next_id = next_id + 1

  local buf = vim.api.nvim_create_buf(true, false)
  local chan, job_id

  local shell = vim.o.shell ~= "" and vim.o.shell or (vim.fn.has("win32") == 1 and "cmd.exe" or "/bin/sh")

  -- open_term gives us a terminal display buffer; on_input handles host keystrokes.
  chan = vim.api.nvim_open_term(buf, {
    on_input = function(_, _, _, data)
      if job_id then
        vim.fn.chansend(job_id, data)
      end
    end,
  })

  pcall(vim.api.nvim_buf_set_name, buf, "liveshare://terminal/" .. term_id)

  job_id = vim.fn.jobstart(shell, {
    pty = true,
    width = 220,
    height = 50,
    on_stdout = vim.schedule_wrap(function(_, data, _)
      if not data then
        return
      end
      -- Remove trailing empty string that Neovim appends after the last \n.
      if data[#data] == "" then
        table.remove(data)
      end
      if #data == 0 then
        return
      end
      local output = table.concat(data, "\n")
      pcall(vim.api.nvim_chan_send, chan, output)
      local entry = terminals[term_id]
      if entry and entry.scrollback then
        scrollback.append(entry.scrollback, output)
      end
      if send_fn then
        send_fn({ t = "terminal_data", term_id = term_id, data = output })
      end
    end),
    on_exit = vim.schedule_wrap(function()
      dbg("terminal " .. term_id .. " shell exited")
      if send_fn then
        send_fn({ t = "terminal_close", term_id = term_id })
      end
      terminals[term_id] = nil
    end),
  })

  if job_id == 0 or job_id == -1 then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    vim.notify("live-share: failed to spawn shell (" .. shell .. ")", vim.log.levels.ERROR)
    return
  end

  terminals[term_id] = {
    chan = chan,
    buf = buf,
    job_id = job_id,
    name = shell,
    scrollback = scrollback.new(scrollback_max),
  }

  if send_fn then
    send_fn({ t = "terminal_open", term_id = term_id, name = shell })
  end

  vim.api.nvim_set_current_buf(buf)
  vim.cmd("startinsert")
  dbg("shared terminal " .. term_id .. " opened (job=" .. job_id .. ")")
end

-- Called when a guest sends terminal_input.
function M.on_guest_input(term_id, data)
  local t = terminals[term_id]
  if not (t and t.job_id) then
    return
  end
  vim.fn.chansend(t.job_id, data)
end

-- Replay every currently open shared terminal to a single peer.  Called by the
-- host right after `open_files_snapshot` so a freshly approved guest sees both
-- the terminals that exist and their recent scrollback, even though those
-- `terminal_open` / `terminal_data` events were broadcast before they joined.
-- `send_one` is invoked once per message, with the same shape used on the live
-- broadcast path; the protocol is unchanged.
function M.snapshot_for(send_one)
  if not send_one then
    return
  end
  for term_id, t in pairs(terminals) do
    if t.scrollback then -- host-side terminal record
      send_one({ t = "terminal_open", term_id = term_id, name = t.name })
      if not scrollback.is_empty(t.scrollback) then
        send_one({ t = "terminal_data", term_id = term_id, data = scrollback.concat(t.scrollback) })
      end
    end
  end
end

-- Test hooks: insert a fake host-side terminal and feed scrollback into it
-- without spawning a real shell.  Only used by the test suite.
function M._test_seed_terminal(term_id, name)
  terminals[term_id] = {
    name = name,
    scrollback = scrollback.new(scrollback_max),
  }
end

function M._test_record(term_id, data)
  local t = terminals[term_id]
  if not (t and t.scrollback) then
    return
  end
  scrollback.append(t.scrollback, data)
end

-- ── Guest ─────────────────────────────────────────────────────────────────────

-- Called when terminal_open arrives from the host.
function M.open_guest(term_id, name)
  if terminals[term_id] then
    return
  end

  local buf = vim.api.nvim_create_buf(true, false)
  local chan = vim.api.nvim_open_term(buf, {
    on_input = function(_, _, _, data)
      if send_fn then
        send_fn({ t = "terminal_input", term_id = term_id, data = data })
      end
    end,
  })

  pcall(vim.api.nvim_buf_set_name, buf, "liveshare://terminal/" .. term_id .. "/" .. (name or "shell"))

  terminals[term_id] = { chan = chan, buf = buf }

  vim.api.nvim_set_current_buf(buf)
  vim.cmd("startinsert")
  dbg("guest terminal " .. term_id .. " opened")
end

-- Called when terminal_data arrives: feed raw output into the terminal display.
function M.on_data(term_id, data)
  local t = terminals[term_id]
  if not (t and data) then
    return
  end
  pcall(vim.api.nvim_chan_send, t.chan, data)
end

-- Called when terminal_close arrives.
function M.on_close(term_id)
  local t = terminals[term_id]
  if not t then
    return
  end
  terminals[term_id] = nil
  vim.api.nvim_out_write("live-share: shared terminal " .. term_id .. " closed\n")
end

-- ── Cleanup ───────────────────────────────────────────────────────────────────

function M.stop()
  for tid, t in pairs(terminals) do
    if t.job_id then
      pcall(vim.fn.jobstop, t.job_id)
    end
    if t.buf and vim.api.nvim_buf_is_valid(t.buf) then
      pcall(vim.api.nvim_buf_delete, t.buf, { force = true })
    end
    terminals[tid] = nil
  end
  next_id = 1
  role = nil
  send_fn = nil
end

return M
