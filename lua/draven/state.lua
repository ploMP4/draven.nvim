---Persisted review state.
---
---Marks are stored against `content_hash`, never against a path and line
---number. That is the whole point: an edit somewhere else in the file cannot
---invalidate a mark, and a hunk that moves keeps it.
---
---The file is plain JSON under the git dir so it is greppable, diffable and
---hand-fixable when something goes wrong.
local log = require("draven.util.log")

local M = {}

M.VERSION = 1

---@class draven.MarkRecord
---@field at integer # unix time the mark was made
---@field path string # also the lookup key for same-file matching
---@field content_hash string # the key this record is stored under
---@field anchor_key string|nil # whitespace-normalised, for re-anchoring
---@field old_start integer|nil # base-side address, stable while base_rev is
---@field old_count integer|nil
---@field snapshot boolean|nil # whether the approved post-image was stored

---@class draven.State
---@field version integer
---@field key string
---@field base string
---@field base_rev string|nil
---@field created_at integer
---@field updated_at integer
---@field reviewed table<string, draven.MarkRecord>
---@field findings table<string, draven.Finding>

---Stable, filesystem-safe name for a changeset's state file.
---@param cs draven.Changeset
---@return string
function M.key(cs)
	local spec = cs.revspec
	local raw = ("%s@%s"):format(spec.kind, spec.arg ~= "" and spec.arg or spec.base)

	local slug = raw:gsub("[^%w@%.%-_]", "-")
	if #slug > 80 then
		-- Keep it recognisable, but bounded.
		slug = slug:sub(1, 72) .. "-" .. vim.fn.sha256(raw):sub(1, 7)
	end

	return slug
end

---@param cs draven.Changeset
---@return string dir
function M.dir(cs)
	return cs.git_dir .. "/draven"
end

---@param cs draven.Changeset
---@return string
function M.path(cs)
	return ("%s/%s.json"):format(M.dir(cs), M.key(cs))
end

---@param cs draven.Changeset
---@return draven.State
local function empty(cs)
	local now = os.time()
	return {
		version = M.VERSION,
		key = M.key(cs),
		base = cs.revspec.base,
		base_rev = cs.base_rev,
		created_at = now,
		updated_at = now,
		reviewed = {},
		findings = {},
	}
end

---Read the state for a changeset, or a fresh one when there is nothing on disk
---or the file is unusable.
---@param cs draven.Changeset
---@return draven.State
function M.load(cs)
	local path = M.path(cs)

	if vim.fn.filereadable(path) == 0 then
		return empty(cs)
	end

	local ok, decoded = pcall(function()
		return vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
	end)

	if not ok or type(decoded) ~= "table" then
		log.warn(("could not read %s, starting a fresh review"):format(path))
		return empty(cs)
	end

	if decoded.version ~= M.VERSION then
		log.warn(("state file is version %s, expected %d — starting fresh"):format(
			tostring(decoded.version),
			M.VERSION
		))
		return empty(cs)
	end

	-- `vim.json.decode` turns an empty object into an empty table, which Lua
	-- cannot tell from an empty array; either way an empty map is correct.
	decoded.reviewed = type(decoded.reviewed) == "table" and decoded.reviewed or {}
	decoded.findings = type(decoded.findings) == "table" and decoded.findings or {}

	return decoded
end

---@param state draven.State
---@param path string
---@return boolean ok
function M.save(state, path)
	state.updated_at = os.time()

	local dir = vim.fn.fnamemodify(path, ":h")
	if vim.fn.isdirectory(dir) == 0 then
		vim.fn.mkdir(dir, "p")
	end

	local ok, encoded = pcall(vim.json.encode, state)
	if not ok then
		log.error("could not encode review state: " .. tostring(encoded))
		return false
	end

	local written = pcall(vim.fn.writefile, { encoded }, path)
	if not written then
		log.error("could not write review state to " .. path)
		return false
	end

	return true
end

--- Snapshots ----------------------------------------------------------------
---
---The post-image of every hunk you approve, so that when the agent rewrites it
---there is something to diff the new version against. Content-addressed, so
---identical hunks share one file and re-approving costs nothing.

---Scoped per review target. Sharing one directory across revspecs would let
---pruning one review delete snapshots another still refers to.
---@param cs draven.Changeset
---@return string
function M.snapshot_dir(cs)
	return ("%s/snapshots/%s"):format(M.dir(cs), M.key(cs))
end

---@param cs draven.Changeset
---@param content_hash string
---@return string
function M.snapshot_path(cs, content_hash)
	return ("%s/%s"):format(M.snapshot_dir(cs), content_hash)
end

---@param cs draven.Changeset
---@param content_hash string
---@param lines string[]
---@return boolean stored
function M.write_snapshot(cs, content_hash, lines)
	local path = M.snapshot_path(cs, content_hash)
	if vim.fn.filereadable(path) == 1 then
		return true -- content-addressed: already exactly this
	end

	local dir = M.snapshot_dir(cs)
	if vim.fn.isdirectory(dir) == 0 then
		vim.fn.mkdir(dir, "p")
	end

	return pcall(vim.fn.writefile, lines, path)
end

---@param cs draven.Changeset
---@param content_hash string
---@return string[]|nil
function M.read_snapshot(cs, content_hash)
	local path = M.snapshot_path(cs, content_hash)
	if vim.fn.filereadable(path) == 0 then
		return nil
	end

	local ok, lines = pcall(vim.fn.readfile, path)
	return ok and lines or nil
end

---Delete snapshots no mark refers to any more.
---@param cs draven.Changeset
---@param state draven.State
---@return integer removed
function M.prune_snapshots(cs, state)
	local dir = M.snapshot_dir(cs)
	if vim.fn.isdirectory(dir) == 0 then
		return 0
	end

	local removed = 0
	for _, path in ipairs(vim.fn.glob(dir .. "/*", true, true)) do
		local hash = vim.fn.fnamemodify(path, ":t")
		if not state.reviewed[hash] then
			vim.fn.delete(path)
			removed = removed + 1
		end
	end

	return removed
end

---Forget a changeset's state entirely.
---@param cs draven.Changeset
function M.delete(cs)
	local path = M.path(cs)
	if vim.fn.filereadable(path) == 1 then
		vim.fn.delete(path)
	end
end

return M
