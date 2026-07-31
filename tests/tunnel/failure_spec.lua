-- Regression tests for tunnel failure reporting.
--
-- A tunnel that never came up has no URL to fall back on.  Before these tests
-- nothing checked the process exit status and any pattern match counted as
-- success, so a provider's *error output* could be scraped into a share URL and
-- copied to the clipboard under the usual success message.
--
-- Coverage:
--   1. A provider that exits non-zero publishes no URL and reports an error.
--   2. The reported failure quotes the provider's own error line.
--   3. Output that never matches the pattern gives up at max_attempts instead
--      of polling forever in silence.
--   4. An empty file and a missing file still report, as before.
--   5. The happy path still publishes, including for a provider that exits 0
--      right after announcing (the LAN recipe shape).

local provider = require("live-share.provider")
local tunnel = require("live-share.tunnel")

describe("tunnel failure reporting", function()
  local errors, outs, url_file, restore_api

  -- Capture what the user would actually see.
  local function capture_messages()
    local err_original = vim.api.nvim_err_writeln
    local out_original = vim.api.nvim_out_write
    vim.api.nvim_err_writeln = function(msg)
      errors[#errors + 1] = msg
    end
    vim.api.nvim_out_write = function(msg)
      outs[#outs + 1] = msg
    end
    return function()
      vim.api.nvim_err_writeln = err_original
      vim.api.nvim_out_write = out_original
    end
  end

  -- Registers a provider built from `command_fn(port, service_url)`, starts the
  -- tunnel, and waits until it either publishes a URL or reports a failure.
  local function run(command_fn, pattern, max_attempts)
    provider.register("test-provider", {
      command = function(_, port, service_url)
        return command_fn(port, service_url)
      end,
      pattern = pattern,
    })
    tunnel.setup({
      service = "test-provider",
      service_url = url_file,
      port_internal = 9876,
      max_attempts = max_attempts or 4, -- × 250 ms
    })
    tunnel.start(9876)
    vim.wait(5000, function()
      return tunnel.last_url ~= nil or #errors > 0
    end)
  end

  -- Writes `text` to the service URL file, then either exits with `code` or
  -- stays alive like a real tunnel would.
  local function writer(text, code)
    return function(_, service_url)
      -- jobstart already runs the command through the shell, so no `bash -c`
      -- wrapper here: nesting one would collide with shellescape's quoting.
      local tail = code and ("exit " .. code) or "sleep 30"
      return string.format("printf %s > %s; %s", vim.fn.shellescape(text), service_url, tail)
    end
  end

  local function joined_errors()
    return table.concat(errors, "\n")
  end

  before_each(function()
    errors, outs = {}, {}
    restore_api = capture_messages()
    url_file = vim.fn.tempname() .. ".url"
    tunnel.last_url = nil
  end)

  after_each(function()
    tunnel.stop()
    restore_api()
    vim.fn.delete(url_file)
  end)

  it("does not publish a URL when the provider exits with an error", function()
    -- bore's real failure output.  "bore.pub:7835" is its control port, which a
    -- naive "bore%.pub:%d+" pattern happily matches.
    run(writer("Error: could not connect to bore.pub:7835\\n\\nCaused by:\\n    timed out\\n", 1), "bore%.pub:%d+")

    assert.is_nil(tunnel.last_url)
    assert.equals(0, #outs, "a success message was printed for a failed tunnel: " .. table.concat(outs, " "))
    assert.is_true(#errors > 0, "the failure was not reported")
  end)

  it("quotes the provider's error line in the failure message", function()
    run(writer("Error: could not connect to bore.pub:7835\\n", 1), "bore%.pub:%d+")

    local reported = joined_errors()
    assert.is_truthy(reported:match("could not connect"), "error not quoted back: " .. reported)
    assert.is_truthy(reported:match("test%-provider"), "provider not named: " .. reported)
  end)

  it("gives up when the output never matches the pattern", function()
    -- Non-empty, non-matching output used to skip the max_attempts check
    -- entirely, leaving a 250 ms timer running for the rest of the session.
    run(writer("ssh: connect to host x port 22: Connection refused\\n"), "bore%.pub:%d+")

    assert.is_nil(tunnel.last_url)
    assert.is_true(#errors > 0, "a non-matching tunnel never reported anything")
    assert.is_truthy(joined_errors():match("did not contain a share URL"), joined_errors())
  end)

  it("still reports an empty file", function()
    run(writer(""), "bore%.pub:%d+")

    assert.is_nil(tunnel.last_url)
    assert.is_true(#errors > 0)
  end)

  it("still reports a missing file", function()
    run(function()
      return "sleep 30"
    end, "bore%.pub:%d+")

    assert.is_nil(tunnel.last_url)
    assert.is_truthy(joined_errors():match("not found"), joined_errors())
  end)

  it("publishes the URL from a provider that comes up normally", function()
    run(writer("INFO listening at bore.pub:41287\\n"), "listening at (bore%.pub:%d+)")

    assert.equals("bore.pub:41287", tunnel.last_url)
    assert.equals(0, #errors, joined_errors())
  end)

  it("publishes for a provider that exits cleanly after announcing", function()
    -- The LAN recipe's shape, minus the `sleep infinity` keep-alive: exit 0 is
    -- not a failure, so the announced address must still be published.
    run(writer("tcp://192.168.1.42:9876\\n", 0), "tcp://[%w._-]+:%d+")

    assert.equals("tcp://192.168.1.42:9876", tunnel.last_url)
    assert.equals(0, #errors, joined_errors())
  end)
end)

describe("documented bore pattern", function()
  -- The pattern shipped in README.md / RECIPES.md, checked directly against
  -- both of bore's output lines.
  local pat = "listening at (bore%.pub:%d+)"

  it("does not match bore's failure line", function()
    assert.is_nil(("Error: could not connect to bore.pub:7835"):match(pat))
  end)

  it("captures the address from bore's success line", function()
    assert.equals("bore.pub:41287", ("INFO bore_cli::client: listening at bore.pub:41287"):match(pat))
  end)
end)
