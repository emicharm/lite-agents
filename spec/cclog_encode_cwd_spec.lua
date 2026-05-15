-- Tests for util.encode_claude_cwd: the function that turns an absolute cwd
-- into the single directory name claude uses under ~/.claude/projects/.
--
-- Run from the project root: `busted spec/cclog_encode_cwd_spec.lua`. The
-- .busted file at the project root sets package.path so `require
-- "plugins.cclog.util"` resolves under `data/`.
--
-- The "real-world" describe block walks ~/.claude/projects/, reads the `cwd`
-- field recorded inside each session's JSONL, and verifies our encoder
-- reproduces the directory name. This is how the editor "knows" the cwd at
-- runtime: claude itself records it on every message, and the on-disk
-- directory name is always encode(that cwd). It's skipped if the projects
-- root or its session files don't exist on this machine, so the spec is
-- portable.

-- util.lua's other functions reach for `system.get_file_info`, which is a
-- C-injected global that doesn't exist outside the editor. Stub the bits we
-- might pull in transitively so `require` succeeds.
_G.system = _G.system or {}

local util = require "plugins.cclog.util"
local json = require "libraries.json"

local encode = util.encode_claude_cwd

describe("util.encode_claude_cwd", function()
  describe("synthetic cases (one rule per char class)", function()
    it("maps '/' to '-'", function()
      assert.equals("-Users-emi-playground-Github-lite",
                    encode("/Users/emi/playground/Github/lite"))
    end)

    it("maps '.' to '-' (so dotfiles double up the leading dash)", function()
      assert.equals("-Users-emi--claude-mem-observer-sessions",
                    encode("/Users/emi/.claude-mem/observer-sessions"))
    end)

    it("maps '_' to '-'", function()
      assert.equals("-Users-emi-playground-utils-cc-log-lovr-viewer",
                    encode("/Users/emi/playground/utils/cc_log/lovr_viewer"))
    end)

    it("maps spaces and brackets to '-' (each char maps independently)", function()
      assert.equals("-Users-emi-Downloads--ScrewThisNoise--HoneyCome-Dolce",
                    encode("/Users/emi/Downloads/[ScrewThisNoise] HoneyCome Dolce"))
    end)

    it("collapses '.' inside version-like segments", function()
      assert.equals("-tmp-Qwen3-5-9B-MLX-4bit",
                    encode("/tmp/Qwen3.5-9B-MLX-4bit"))
    end)

    it("preserves existing '-' (only non-[A-Za-z0-9-] is rewritten)", function()
      assert.equals("-a-b-c", encode("/a-b-c"))
    end)

    it("preserves capitalisation", function()
      assert.equals("-Users-emi-playground-Github-lite",
                    encode("/Users/emi/playground/Github/lite"))
    end)

    it("returns '' for empty / nil input", function()
      assert.equals("", encode(""))
      assert.equals("", encode(nil))
    end)
  end)

  -- ── Real-data oracle ────────────────────────────────────────────────────
  --
  -- For each project dir that has at least one JSONL with a recorded `cwd`
  -- field, assert encode(cwd) == directory name. This pins the encoder to
  -- claude's actual on-disk behavior across whatever projects this machine
  -- has accumulated.
  describe("matches every project dir under ~/.claude/projects", function()
    local home = os.getenv("HOME")
    local root = home and (home .. "/.claude/projects") or nil

    local function dir_exists(p)
      local f = io.open(p, "rb")
      if f then f:close(); return true end
      -- Try opening as a directory listing on POSIX:
      local p2 = io.popen('test -d "' .. p .. '" && echo y')
      if not p2 then return false end
      local ok = (p2:read("*l") == "y"); p2:close(); return ok
    end

    local function list_dirs(p)
      local out = {}
      local h = io.popen('ls -1 "' .. p .. '" 2>/dev/null')
      if not h then return out end
      for line in h:lines() do out[#out + 1] = line end
      h:close()
      return out
    end

    local function list_jsonl(p)
      local out = {}
      local h = io.popen('ls -1 "' .. p .. '"/*.jsonl 2>/dev/null')
      if not h then return out end
      for line in h:lines() do out[#out + 1] = line end
      h:close()
      return out
    end

    -- Scan the first ~32 lines of a session for a `cwd` field. Many claude
    -- session files only carry `cwd` on the first user/assistant record, not
    -- on metadata lines, so cap the search rather than reading the whole file.
    local function read_recorded_cwd(path)
      local f = io.open(path, "rb"); if not f then return nil end
      local n = 0
      for line in f:lines() do
        n = n + 1
        if line:find('"cwd"', 1, true) then
          local ok, obj = pcall(json.decode, line)
          if ok and type(obj) == "table" and obj.cwd and obj.cwd ~= "" then
            f:close(); return obj.cwd
          end
        end
        if n >= 32 then break end
      end
      f:close(); return nil
    end

    if not root or not dir_exists(root) then
      pending("no ~/.claude/projects on this machine — skipping")
      return
    end

    local pairs_checked = {}
    for _, dirname in ipairs(list_dirs(root)) do
      local full = root .. "/" .. dirname
      local files = list_jsonl(full)
      for _, fp in ipairs(files) do
        local cwd = read_recorded_cwd(fp)
        if cwd then
          pairs_checked[#pairs_checked + 1] = { dir = dirname, cwd = cwd }
          break
        end
      end
    end

    if #pairs_checked == 0 then
      pending("no session files with a recorded cwd — skipping")
      return
    end

    it(("checks at least one project (%d found)"):format(#pairs_checked), function()
      assert.is_true(#pairs_checked > 0)
    end)

    for _, pc in ipairs(pairs_checked) do
      it(("encode(%s) == %s"):format(pc.cwd, pc.dir), function()
        assert.equals(pc.dir, encode(pc.cwd))
      end)
    end
  end)
end)
