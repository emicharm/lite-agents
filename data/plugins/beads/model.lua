-- beads/model.lua
--
-- Snapshot of `bd list` plus a hierarchy view derived from issue id shape
-- (`lite-1.2.3` → child of `lite-1.2`). Collapse state lives here so it
-- survives refresh.

local core = require "core"
local cli  = require "plugins.beads.cli"

local M = {}

M.STATUS_COLOR = {
  open         = "dim",
  in_progress  = "accent",
  blocked      = "syntax.keyword",
  deferred     = "dim",
  closed       = "syntax.comment",
}

M.PRIORITY_STYLE = {
  [0] = "syntax.keyword",
  [1] = "syntax.number",
  [2] = "syntax.literal",
  [3] = "syntax.comment",
  [4] = "dim",
}

M.TYPE_BADGE = {
  task = "T", bug = "B", feature = "F", chore = "C", epic = "E",
  decision = "D", spike = "S", story = "Y", milestone = "M",
}

M.state = {
  ready      = false,
  error      = nil,
  workspace  = nil,
  issues     = {},
  by_id      = {},
  collapsed  = {},
  fetched_at = 0,
}

function M.priority_label(n)
  if type(n) == "number" and n >= 0 and n <= 4 then
    return "P" .. n
  end
  return "—"
end

-- `lite-1.2.3` → `lite-1.2`. Returns nil for top-level ids (`lite-1` or
-- `lite-bxl`). Only splits on dots, not dashes — `lite-bxl` is a single
-- top-level id, not a child of `lite`.
local function parent_from_id(id)
  if type(id) ~= "string" then return nil end
  local prefix, dotted = id:match("^([^%-]+%-[^%.]+)%.(.+)$")
  if not prefix then return nil end
  local last = dotted:match("^(.+)%.[^%.]+$")
  if last then return prefix .. "." .. last end
  return prefix
end

function M.set_issues(list)
  list = list or {}
  M.state.issues = list
  M.state.by_id = {}
  for _, it in ipairs(list) do
    if it.id then M.state.by_id[it.id] = it end
  end
  M.state.ready = true
  M.state.fetched_at = system.get_time()
  core.redraw = true
end

function M.toggle_collapse(id)
  M.state.collapsed[id] = not M.state.collapsed[id] or nil
  core.redraw = true
end

function M.refresh_sync(project_dir)
  local ws = cli.workspace_root(project_dir)
  M.state.workspace = ws
  if not ws then
    M.state.error = "no_workspace"
    M.state.issues = {}
    M.state.by_id = {}
    M.state.ready = true
    core.redraw = true
    return
  end
  local data, err = cli.run(
    "list --status open,in_progress,blocked,deferred --sort priority --limit 0",
    ws)
  if not data then
    M.state.error = err
    return
  end
  M.state.error = nil
  M.set_issues(data)
end

-- Build a flat row list from M.state.issues respecting:
--   * parent/child relationships derived from id shape (or `parent` field)
--   * collapse state
--   * top-level order: priority asc, then created asc
--   * children inherit parent ordering
-- Each row is { issue=..., depth=N, has_children=bool, orphan=bool }.
function M.group_tree()
  local issues = M.state.issues
  local by_id  = M.state.by_id
  local children = {}     -- parent_id -> list of child issues
  local roots = {}

  for _, it in ipairs(issues) do
    local p = it.parent or it.parent_id or parent_from_id(it.id)
    if p and by_id[p] then
      children[p] = children[p] or {}
      table.insert(children[p], it)
    elseif p then
      it._orphan = true
      table.insert(roots, it)
    else
      it._orphan = false
      table.insert(roots, it)
    end
  end

  local function cmp(a, b)
    local pa = type(a.priority) == "number" and a.priority or 99
    local pb = type(b.priority) == "number" and b.priority or 99
    if pa ~= pb then return pa < pb end
    return (a.created_at or "") < (b.created_at or "")
  end
  table.sort(roots, cmp)
  for _, kids in pairs(children) do table.sort(kids, cmp) end

  local rows = {}
  local function emit(it, depth)
    local kids = children[it.id]
    table.insert(rows, {
      issue = it,
      depth = depth,
      has_children = kids ~= nil and #kids > 0,
      orphan = it._orphan,
    })
    if kids and not M.state.collapsed[it.id] then
      for _, c in ipairs(kids) do emit(c, depth + 1) end
    end
  end
  for _, r in ipairs(roots) do emit(r, 0) end
  return rows
end

return M
