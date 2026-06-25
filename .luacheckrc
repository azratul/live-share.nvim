-- Luacheck configuration for live-share.nvim
-- Focus: catch real defects (undefined globals, unused/dead locals, typos).
-- Formatting (line length, whitespace) is StyLua's job, not luacheck's.

std = "luajit"
cache = true
codes = true

-- Neovim plugins legitimately assign to vim.bo / vim.b / vim.g / vim.opt …,
-- so treat `vim` as a writable global instead of read-only (avoids 25 false
-- "setting read-only field of global 'vim'" reports).
globals = {
  "vim",
}

-- Methods frequently don't reference `self`; don't flag that.
self = false

-- StyLua already enforces the 120-column width from stylua.toml.
max_line_length = false

-- Stylistic checks we intentionally don't enforce on this codebase:
--   212  unused argument        — callbacks must match a fixed signature
--   421/431/432  shadowing      — reusing err/ok/data in nested callbacks is idiomatic
--   542  empty if branch        — used deliberately to absorb a message (e.g. pong)
ignore = {
  "212",
  "421",
  "431",
  "432",
  "542",
}

-- Test files run under plenary's busted-style harness, which provides these
-- as globals.
files["tests/"] = {
  read_globals = {
    "describe",
    "it",
    "before_each",
    "after_each",
    "setup",
    "teardown",
    "pending",
  },
}
