-- Unit tests for lua/live-share/workspace.lua
--
-- Coverage:
--   1. Sandbox: rejects path traversal, absolute paths, NUL bytes, symlinks
--      that escape the workspace root
--   2. Sensitive-file filter: hides .env, SSH keys, AWS/kube creds, *.pem,
--      *.key, .npmrc, .pypirc, .netrc from scan() and refuses read/write
--   3. Opt-out via allow_sensitive_files = true
--   4. Extra patterns via extra_sensitive_patterns
--
-- Run with:
--   nvim --headless -u tests/minimal_init.lua \
--     -c "PlenaryBustedDirectory tests/ {minimal_init='tests/minimal_init.lua'}"

local workspace = require("live-share.workspace")
local uv = vim.uv or vim.loop

local function tmpdir()
  local p = vim.fn.tempname()
  vim.fn.mkdir(p, "p")
  return p
end

local function write(path, content)
  local fd, err = uv.fs_open(path, "w", 420)
  assert(fd, "fs_open failed for " .. tostring(path) .. ": " .. tostring(err))
  uv.fs_write(fd, content or "x", 0)
  uv.fs_close(fd)
end

local function rmrf(path)
  vim.fn.delete(path, "rf")
end

describe("workspace", function()
  local root, outside

  before_each(function()
    root = tmpdir()
    outside = tmpdir()
    workspace.setup({})
    workspace.set_root(root)
  end)

  after_each(function()
    workspace.set_root(nil)
    rmrf(root)
    rmrf(outside)
  end)

  describe("sandbox", function()
    it("reads files inside the workspace", function()
      write(root .. "/a.txt", "hello\nworld")
      local lines = workspace.read_file("a.txt")
      assert.same({ "hello", "world" }, lines)
    end)

    it("reads files in subdirectories", function()
      vim.fn.mkdir(root .. "/sub", "p")
      write(root .. "/sub/file.txt", "ok")
      assert.same({ "ok" }, workspace.read_file("sub/file.txt"))
    end)

    it("rejects '..' traversal", function()
      write(outside .. "/secret.txt", "leaked")
      assert.is_nil(workspace.read_file("../secret.txt"))
      assert.is_nil(workspace.read_file("sub/../../secret.txt"))
      assert.is_nil(workspace.read_file(".."))
    end)

    it("rejects absolute paths", function()
      -- Use the cross-platform `outside` tempdir (the previous /tmp path didn't
      -- exist on Windows runners and made the test crash before asserting).
      local target = outside .. "/secret.txt"
      write(target, "leak")
      assert.is_nil(workspace.read_file(target))
      assert.is_nil(workspace.read_file("/etc/passwd"))
      assert.is_nil(workspace.read_file("C:/Windows/System32/drivers/etc/hosts"))
    end)

    it("rejects NUL bytes", function()
      assert.is_nil(workspace.read_file("a\0b"))
    end)

    it("rejects symlinks that escape the workspace", function()
      write(outside .. "/secret.txt", "leaked")
      uv.fs_symlink(outside .. "/secret.txt", root .. "/link")
      assert.is_nil(workspace.read_file("link"))
    end)

    it("write_file refuses to write outside the workspace via traversal", function()
      assert.is_false(workspace.write_file("../escaped.txt", { "no" }))
      assert.is_nil(uv.fs_stat(outside .. "/escaped.txt"))
    end)
  end)

  describe("sensitive-file filter (default)", function()
    it("excludes .env from scan()", function()
      write(root .. "/.env", "SECRET=1")
      write(root .. "/normal.txt", "ok")
      local files = workspace.scan()
      assert.same({ "normal.txt" }, files)
    end)

    it("excludes SSH keys from scan()", function()
      vim.fn.mkdir(root .. "/keys", "p")
      write(root .. "/keys/id_rsa", "PRIVATE")
      write(root .. "/keys/id_ed25519", "PRIVATE")
      write(root .. "/keys/regular.txt", "ok")
      local files = workspace.scan()
      assert.same({ "keys/regular.txt" }, files)
    end)

    it("excludes *.pem and *.key files", function()
      write(root .. "/cert.pem", "-----BEGIN CERTIFICATE-----")
      write(root .. "/server.key", "-----BEGIN PRIVATE KEY-----")
      write(root .. "/notes.txt", "ok")
      assert.same({ "notes.txt" }, workspace.scan())
    end)

    it("excludes .aws/ and .kube/ subtrees", function()
      vim.fn.mkdir(root .. "/.aws", "p")
      write(root .. "/.aws/credentials", "[default]\nkey=AKIA…")
      vim.fn.mkdir(root .. "/.kube", "p")
      write(root .. "/.kube/config", "apiVersion: v1")
      write(root .. "/visible.txt", "ok")
      -- .aws and .kube also start with a dot so they're already filtered by the
      -- top-level dotfile rule.  This test guards against a future change that
      -- would re-enable dotfile traversal.
      assert.same({ "visible.txt" }, workspace.scan())
    end)

    it("read_file returns nil for sensitive paths even if they exist", function()
      write(root .. "/.env", "SECRET=1")
      assert.is_nil(workspace.read_file(".env"))
    end)

    it("write_file refuses to overwrite sensitive paths", function()
      write(root .. "/cert.pem", "old")
      assert.is_false(workspace.write_file("cert.pem", { "new" }))
      -- Original content untouched.
      local fd = uv.fs_open(root .. "/cert.pem", "r", 0)
      local stat = uv.fs_fstat(fd)
      assert.equals("old", uv.fs_read(fd, stat.size, 0))
      uv.fs_close(fd)
    end)

    it("is_sensitive() identifies the obvious cases", function()
      assert.is_true(workspace.is_sensitive(".env"))
      assert.is_true(workspace.is_sensitive(".env.local"))
      assert.is_true(workspace.is_sensitive("cert.pem"))
      assert.is_true(workspace.is_sensitive("foo/server.key"))
      assert.is_true(workspace.is_sensitive("ssh/id_rsa"))
      assert.is_true(workspace.is_sensitive(".npmrc"))
      assert.is_false(workspace.is_sensitive("normal.txt"))
      assert.is_false(workspace.is_sensitive("src/main.lua"))
    end)
  end)

  describe("sensitive-file filter (opt-out)", function()
    it("scan() includes non-dotfile sensitives when allow_sensitive_files = true", function()
      workspace.setup({ allow_sensitive_files = true })
      workspace.set_root(root)
      -- cert.pem is sensitive but not a dotfile, so the only filter that
      -- would exclude it is the sensitive-file filter (which we just disabled).
      write(root .. "/cert.pem", "PRIVATE")
      write(root .. "/normal.txt", "ok")
      local files = workspace.scan()
      table.sort(files)
      assert.same({ "cert.pem", "normal.txt" }, files)
    end)

    it("read_file allows sensitive paths when allow_sensitive_files = true", function()
      workspace.setup({ allow_sensitive_files = true })
      workspace.set_root(root)
      write(root .. "/.env", "SECRET=1")
      assert.same({ "SECRET=1" }, workspace.read_file(".env"))
    end)
  end)

  describe("extra_sensitive_patterns", function()
    it("blocks user-supplied patterns in addition to defaults", function()
      workspace.setup({ extra_sensitive_patterns = { "%.tfstate$" } })
      workspace.set_root(root)
      write(root .. "/state.tfstate", "{}")
      write(root .. "/normal.txt", "ok")
      assert.same({ "normal.txt" }, workspace.scan())
      assert.is_nil(workspace.read_file("state.tfstate"))
    end)
  end)

  describe("scan ignore list (walk mode)", function()
    it("skips built-in noise dirs (target, .venv, .next, ...)", function()
      vim.fn.mkdir(root .. "/target", "p")
      write(root .. "/target/release.bin", "x")
      vim.fn.mkdir(root .. "/.venv/lib", "p")
      write(root .. "/.venv/lib/site.py", "x")
      vim.fn.mkdir(root .. "/.next", "p")
      write(root .. "/.next/build.json", "{}")
      write(root .. "/src.lua", "ok")
      assert.same({ "src.lua" }, workspace.scan())
    end)

    it("scan_extra_ignore stacks additional dir basenames", function()
      workspace.setup({ scan_extra_ignore = { "fixtures", "snapshots" } })
      workspace.set_root(root)
      vim.fn.mkdir(root .. "/fixtures", "p")
      write(root .. "/fixtures/a.txt", "x")
      vim.fn.mkdir(root .. "/snapshots", "p")
      write(root .. "/snapshots/b.txt", "x")
      write(root .. "/keep.txt", "ok")
      assert.same({ "keep.txt" }, workspace.scan())
    end)
  end)

  describe("scan_max_files cap (walk mode)", function()
    it("truncates results at the cap and reports truncation", function()
      workspace.setup({ scan_max_files = 5 })
      workspace.set_root(root)
      for i = 1, 20 do
        write(root .. "/" .. string.format("f%02d.txt", i), "x")
      end
      local files = workspace.scan()
      assert.equals(5, #files)
      assert.is_true(workspace.scan_was_truncated())
    end)

    it("does not flag truncation when the cap is not hit", function()
      workspace.setup({ scan_max_files = 100 })
      workspace.set_root(root)
      for i = 1, 3 do
        write(root .. "/" .. string.format("f%d.txt", i), "x")
      end
      assert.equals(3, #workspace.scan())
      assert.is_false(workspace.scan_was_truncated())
    end)
  end)

  describe("scan via git ls-files", function()
    local function git_init(dir)
      local cmd = string.format(
        "git -C %q init -q && git -C %q config user.email a@b && git -C %q config user.name a",
        dir,
        dir,
        dir
      )
      os.execute(cmd)
    end

    it("respects .gitignore when the workspace is a git repo", function()
      if vim.fn.executable("git") ~= 1 then
        pending("git not available")
        return
      end
      git_init(root)
      write(root .. "/.gitignore", "secret.txt\nbuild/\n")
      write(root .. "/keep.txt", "ok")
      write(root .. "/secret.txt", "no")
      vim.fn.mkdir(root .. "/build", "p")
      write(root .. "/build/out.bin", "x")
      local files = workspace.scan()
      table.sort(files)
      assert.same({ ".gitignore", "keep.txt" }, files)
    end)

    it("includes untracked files (since -o is passed)", function()
      if vim.fn.executable("git") ~= 1 then
        pending("git not available")
        return
      end
      git_init(root)
      write(root .. "/untracked.txt", "ok")
      local files = workspace.scan()
      table.sort(files)
      assert.same({ "untracked.txt" }, files)
    end)

    it("still applies the sensitive-file filter on top of git output", function()
      if vim.fn.executable("git") ~= 1 then
        pending("git not available")
        return
      end
      git_init(root)
      write(root .. "/cert.pem", "PRIVATE")
      write(root .. "/normal.txt", "ok")
      assert.same({ "normal.txt" }, workspace.scan())
    end)

    it("falls back to walk mode when scan_use_gitignore = false", function()
      if vim.fn.executable("git") ~= 1 then
        pending("git not available")
        return
      end
      workspace.setup({ scan_use_gitignore = false })
      workspace.set_root(root)
      git_init(root)
      write(root .. "/.gitignore", "secret.txt\n")
      write(root .. "/keep.txt", "ok")
      write(root .. "/secret.txt", "no")
      -- Walk mode doesn't read .gitignore, so secret.txt would normally appear,
      -- but the dotfile rule still hides .gitignore itself.
      local files = workspace.scan()
      table.sort(files)
      assert.same({ "keep.txt", "secret.txt" }, files)
    end)
  end)
end)
