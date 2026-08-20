---A live review: a changeset joined to its persisted marks.
---
---Everything the UI needs to answer "what is left to read" lives here, and
---nothing in this file touches a window or a buffer.
local anchor = require("draven.core.anchor")
local config = require("draven.config")
local finding_mod = require("draven.finding")
local hunk_mod = require("draven.core.hunk")
local log = require("draven.util.log")
local state_store = require("draven.state")

---@class draven.Session
---@field changeset draven.Changeset
---@field state draven.State
---@field path string # where the state is persisted
---@field order draven.OrderEntry[] # every reviewable hunk, in review order
---@field base_stable boolean # marks were made against the current base
local Session = {}
Session.__index = Session

---@class draven.OrderEntry
---@field file draven.File
---@field hunk draven.Hunk
---@field position integer

local M = { Session = Session }

---@param cs draven.Changeset
---@return draven.Session
function M.new(cs)
	local self = setmetatable({
		changeset = cs,
		state = state_store.load(cs),
		path = state_store.path(cs),
		order = {},
		base_stable = true,
		_status = {},
		_by_path = {},
		_by_anchor = {},
		_findings_by_path = {},
		_save_timer = nil,
	}, Session)

	self:_settle_base()
	self:reindex()
	return self
end

---Base-side addresses are only meaningful against the revision they were
---recorded under. When that moves — you committed, or rebased — drop them and
---keep only what content addressing can still prove.
function Session:_settle_base()
	local current = self.changeset.base_rev

	if not self.state.base_rev then
		self.state.base_rev = current
		return
	end

	if self.state.base_rev == current then
		self.base_stable = true
		return
	end

	local dropped = 0
	for _, record in pairs(self.state.reviewed) do
		if record.old_start then
			record.old_start, record.old_count = nil, nil
			dropped = dropped + 1
		end
	end

	self.state.base_rev = current
	self.base_stable = true

	if dropped > 0 then
		log.info(
			("base revision moved — %d mark%s can no longer be traced to a rewrite"):format(
				dropped,
				dropped == 1 and "" or "s"
			)
		)
		self:save_soon()
	end
end

---Classify a hunk, taking the two hash lookups directly rather than letting
---`anchor.classify` scan for them. Same answer, but O(1) for the common case
---instead of O(marks in this file) — which matters when one file holds
---hundreds of hunks.
---@param hunk draven.Hunk
---@return draven.HunkStatus
---@return draven.MarkRecord|nil
function Session:_classify(hunk)
	local exact = self.state.reviewed[hunk.content_hash]
	if exact then
		return "reviewed", exact
	end

	local reindented = self._by_anchor[hunk.anchor_key]
	if reindented then
		return "reviewed", reindented
	end

	return anchor.classify(hunk, self._by_path[hunk.path], { base_stable = self.base_stable })
end

---Index marks by file and by anchor, then classify every hunk.
function Session:_reclassify()
	self._by_path, self._by_anchor = {}, {}

	for hash, record in pairs(self.state.reviewed) do
		-- Older records were keyed only; make the key reachable from the value.
		record.content_hash = record.content_hash or hash

		local list = self._by_path[record.path]
		if not list then
			list = {}
			self._by_path[record.path] = list
		end
		list[#list + 1] = record

		-- Anchor keys already carry their path, so this cannot collide across
		-- files.
		if record.anchor_key then
			self._by_anchor[record.anchor_key] = record
		end
	end

	self._status = {}
	for _, entry in ipairs(self.order) do
		local status, origin = self:_classify(entry.hunk)
		self._status[entry.hunk.id] = { status = status, origin = origin }
	end
end

---Group findings by file. The panel asks for per-file counts once per row, so
---without this a large changeset scans every finding for every file.
function Session:_index_findings()
	self._findings_by_path = {}

	for _, item in pairs(self.state.findings or {}) do
		local list = self._findings_by_path[item.path]
		if not list then
			list = {}
			self._findings_by_path[item.path] = list
		end
		list[#list + 1] = item
	end

	for _, list in pairs(self._findings_by_path) do
		table.sort(list, finding_mod.before)
	end
end

---Point every finding at whatever now holds the line it was written against.
function Session:_reanchor_findings()
	local changeset = require("draven.core.changeset")

	for _, item in pairs(self.state.findings or {}) do
		finding_mod.reanchor(item, changeset.file(self.changeset, item.path), {
			base_stable = self.base_stable,
		})
	end

	self:_index_findings()
end

---Rebuild the ordered hunk list. Call after replacing the changeset.
function Session:reindex()
	local changeset = require("draven.core.changeset")

	self.order = {}
	for file, hunk in changeset.hunks(self.changeset) do
		self.order[#self.order + 1] = {
			file = file,
			hunk = hunk,
			position = #self.order + 1,
		}
	end

	self:_reclassify()
	self:_reanchor_findings()
end

---Swap in a freshly built changeset, keeping every mark.
---@param cs draven.Changeset
function Session:update(cs)
	self.changeset = cs
	self:_settle_base()
	self:reindex()
end

--- Status --------------------------------------------------------------------

---@param hunk draven.Hunk
---@return draven.HunkStatus
function Session:hunk_state(hunk)
	local cached = self._status[hunk.id]
	if cached then
		return cached.status
	end

	-- Hunks outside the review order (ignored files) are classified on demand.
	return (self:_classify(hunk))
end

---The mark a stale hunk descends from, if any.
---@param hunk draven.Hunk
---@return draven.MarkRecord|nil
function Session:origin_of(hunk)
	local cached = self._status[hunk.id]
	return cached and cached.origin or nil
end

---@param hunk draven.Hunk
---@return boolean
function Session:is_reviewed(hunk)
	return self:hunk_state(hunk) == "reviewed"
end

---The post-image you approved, for diffing against what is there now.
---@param hunk draven.Hunk
---@return string[]|nil
function Session:approved_image(hunk)
	local origin = self:origin_of(hunk)
	if not origin then
		return nil
	end
	return state_store.read_snapshot(self.changeset, origin.content_hash)
end

--- Findings ------------------------------------------------------------------

---Every finding, most severe first.
---@param opts? { unresolved_only?: boolean, path?: string }
---@return draven.Finding[]
function Session:findings(opts)
	opts = opts or {}

	local source
	if opts.path then
		source = self._findings_by_path[opts.path] or {}
	else
		source = {}
		for _, item in pairs(self.state.findings or {}) do
			source[#source + 1] = item
		end
		table.sort(source, finding_mod.before)
	end

	if not opts.unresolved_only then
		-- Per-path lists are already sorted; copy so callers cannot mutate.
		return opts.path and vim.list_slice(source) or source
	end

	local out = {}
	for _, item in ipairs(source) do
		if not item.resolved then
			out[#out + 1] = item
		end
	end
	return out
end

---@param path string
---@param lnum integer
---@return draven.Finding[]
function Session:findings_at(path, lnum)
	local out = {}
	for _, item in ipairs(self._findings_by_path[path] or {}) do
		if item.lnum == lnum then
			out[#out + 1] = item
		end
	end
	return out
end

---@param path string
---@return integer total
---@return integer unresolved
---@return integer orphaned
function Session:finding_counts(path)
	local total, unresolved, orphaned = 0, 0, 0

	for _, item in ipairs(self._findings_by_path[path] or {}) do
		total = total + 1
		if not item.resolved then
			unresolved = unresolved + 1
		end
		if item.state == "orphaned" then
			orphaned = orphaned + 1
		end
	end

	return total, unresolved, orphaned
end

---@param hunk draven.Hunk
---@param lnum integer
---@param opts { body: string, severity: draven.Severity, span?: integer }
---@return draven.Finding|nil
function Session:add_finding(hunk, lnum, opts)
	local item = finding_mod.create(hunk, lnum, opts)
	if not item then
		return nil
	end

	item.lnum, item.state = lnum, "anchored"

	self.state.findings = self.state.findings or {}
	self.state.findings[item.id] = item
	self:_index_findings()
	self:save_soon()

	return item
end

---@param id string
---@return boolean removed
function Session:remove_finding(id)
	if not self.state.findings or not self.state.findings[id] then
		return false
	end

	self.state.findings[id] = nil
	self:_index_findings()
	self:save_soon()
	return true
end

---@param id string
---@param body string
---@param severity draven.Severity
function Session:update_finding(id, body, severity)
	local item = self.state.findings and self.state.findings[id]
	if not item then
		return
	end

	item.body = body
	item.severity = finding_mod.normalize_severity(severity)
	item.updated_at = os.time()
	self:_index_findings()
	self:save_soon()
end

---Collapse a finding's box to a single line, or open it again.
---@param id string
---@return boolean|nil collapsed
function Session:toggle_collapsed(id)
	local item = self.state.findings and self.state.findings[id]
	if not item then
		return nil
	end

	item.collapsed = not item.collapsed or nil
	self:save_soon()
	return item.collapsed == true
end

---@param id string
---@return boolean|nil resolved
function Session:toggle_resolved(id)
	local item = self.state.findings and self.state.findings[id]
	if not item then
		return nil
	end

	item.resolved = not item.resolved
	item.updated_at = os.time()
	self:_index_findings()
	self:save_soon()
	return item.resolved
end

--- Marks ---------------------------------------------------------------------

---@param hunk draven.Hunk
---@return draven.MarkRecord
function Session:_record(hunk)
	local record = {
		at = os.time(),
		path = hunk.path,
		content_hash = hunk.content_hash,
		anchor_key = hunk.anchor_key,
		old_start = hunk.old_start,
		old_count = hunk.old_count,
	}

	local image = hunk_mod.post_image(hunk.lines)
	local bytes = #table.concat(image, "\n")

	if bytes <= config.options.max_snapshot_bytes then
		record.snapshot = state_store.write_snapshot(self.changeset, hunk.content_hash, image)
	end

	return record
end

---@param hunk draven.Hunk
---@param reviewed boolean
function Session:mark(hunk, reviewed)
	if reviewed then
		self.state.reviewed[hunk.content_hash] = self:_record(hunk)
	else
		self.state.reviewed[hunk.content_hash] = nil

		-- Unmarking must clear what made it reviewed, not just the exact
		-- match: a re-anchored whitespace variant would otherwise hold it.
		local origin = self._status[hunk.id] and self._status[hunk.id].origin
		if origin and origin.anchor_key == hunk.anchor_key then
			self.state.reviewed[origin.content_hash] = nil
		end
	end

	self:_reclassify()
	self:save_soon()
end

---@param file draven.File
---@param reviewed boolean
function Session:mark_file(file, reviewed)
	for _, hunk in ipairs(file.hunks) do
		if reviewed then
			self.state.reviewed[hunk.content_hash] = self:_record(hunk)
		else
			self.state.reviewed[hunk.content_hash] = nil
			local cached = self._status[hunk.id]
			if cached and cached.origin then
				self.state.reviewed[cached.origin.content_hash] = nil
			end
		end
	end

	self:_reclassify()
	self:save_soon()
end

---@param reviewed boolean
function Session:mark_all(reviewed)
	for _, entry in ipairs(self.order) do
		if reviewed then
			self.state.reviewed[entry.hunk.content_hash] = self:_record(entry.hunk)
		else
			self.state.reviewed[entry.hunk.content_hash] = nil
			local cached = self._status[entry.hunk.id]
			if cached and cached.origin then
				self.state.reviewed[cached.origin.content_hash] = nil
			end
		end
	end

	self:_reclassify()
	self:save_soon()
end

--- Progress ------------------------------------------------------------------

---@return integer reviewed
---@return integer total
---@return integer stale
function Session:progress()
	local reviewed, stale = 0, 0

	for _, entry in ipairs(self.order) do
		local status = self:hunk_state(entry.hunk)
		if status == "reviewed" then
			reviewed = reviewed + 1
		elseif status == "stale" then
			stale = stale + 1
		end
	end

	return reviewed, #self.order, stale
end

---@param file draven.File
---@return integer reviewed
---@return integer total
---@return integer stale
function Session:file_progress(file)
	local reviewed, stale = 0, 0

	for _, hunk in ipairs(file.hunks) do
		local status = self:hunk_state(hunk)
		if status == "reviewed" then
			reviewed = reviewed + 1
		elseif status == "stale" then
			stale = stale + 1
		end
	end

	return reviewed, #file.hunks, stale
end

---@param file draven.File
---@return "reviewed"|"partial"|"stale"|"unread"|"ignored"|"empty"
function Session:file_state(file)
	if file.ignored then
		return "ignored"
	end
	if #file.hunks == 0 then
		return "empty"
	end

	local reviewed, total, stale = self:file_progress(file)

	-- Anything the agent rewrote under you outranks plain progress: it is the
	-- thing you most need to look at again.
	if stale > 0 then
		return "stale"
	end
	if reviewed == 0 then
		return "unread"
	elseif reviewed == total then
		return "reviewed"
	end
	return "partial"
end

--- Navigation ----------------------------------------------------------------

---@param hunk draven.Hunk
---@return integer|nil
function Session:position_of(hunk)
	for _, entry in ipairs(self.order) do
		if entry.hunk.id == hunk.id then
			return entry.position
		end
	end
	return nil
end

---Walk from `from` looking for a hunk that still needs reading — unread or
---stale, both of which are "not yet approved as it stands".
---@param from integer|nil
---@param backwards? boolean
---@return draven.OrderEntry|nil
function Session:next_unread(from, backwards)
	local count = #self.order
	if count == 0 then
		return nil
	end

	local start = from or (backwards and count + 1 or 0)
	local step = backwards and -1 or 1

	for i = 1, count do
		local index = ((start - 1 + step * i) % count + count) % count + 1
		local entry = self.order[index]
		if self:hunk_state(entry.hunk) ~= "reviewed" then
			return entry
		end
	end

	return nil
end

---@return draven.OrderEntry|nil
function Session:next_stale(from, backwards)
	local count = #self.order
	if count == 0 then
		return nil
	end

	local start = from or (backwards and count + 1 or 0)
	local step = backwards and -1 or 1

	for i = 1, count do
		local index = ((start - 1 + step * i) % count + count) % count + 1
		local entry = self.order[index]
		if self:hunk_state(entry.hunk) == "stale" then
			return entry
		end
	end

	return nil
end

---The first hunk of the changeset, unread ones preferred.
---@return draven.OrderEntry|nil
function Session:first_target()
	return self:next_unread(nil, false) or self.order[1]
end

---@param path string
---@return draven.OrderEntry|nil
function Session:first_in_file(path)
	for _, entry in ipairs(self.order) do
		if entry.file.path == path then
			return entry
		end
	end
	return nil
end

---Which hunk of `file` contains `lnum` in the post-image, if any.
---@param file draven.File
---@param lnum integer
---@return draven.Hunk|nil
function Session:hunk_at(file, lnum)
	for _, hunk in ipairs(file.hunks) do
		local first, last = hunk_mod.new_range(hunk)
		if first == 0 then
			-- A pure deletion occupies no lines; claim the line it hangs off.
			if lnum == math.max(1, hunk.new_start) then
				return hunk
			end
		elseif lnum >= first and lnum <= last then
			return hunk
		end
	end

	return nil
end

---Nearest hunk at or after `lnum`, for when the cursor sits in unchanged code.
---@param file draven.File
---@param lnum integer
---@param backwards? boolean
---@return draven.Hunk|nil
function Session:nearest_hunk(file, lnum, backwards)
	local best

	for _, hunk in ipairs(file.hunks) do
		local first = select(1, hunk_mod.new_range(hunk))
		if first == 0 then
			first = math.max(1, hunk.new_start)
		end

		if backwards then
			if first <= lnum and (not best or first > select(1, hunk_mod.new_range(best))) then
				best = hunk
			end
		else
			if first >= lnum and (not best or first < select(1, hunk_mod.new_range(best))) then
				best = hunk
			end
		end
	end

	return best
end

--- Persistence ---------------------------------------------------------------

---Write now.
function Session:save()
	if self._save_timer then
		self._save_timer:stop()
		self._save_timer:close()
		self._save_timer = nil
	end
	state_store.save(self.state, self.path)
end

---Write shortly, coalescing bursts of marks into one write.
function Session:save_soon()
	if self._save_timer then
		self._save_timer:stop()
	else
		self._save_timer = (vim.uv or vim.loop).new_timer()
	end

	self._save_timer:start(
		400,
		0,
		vim.schedule_wrap(function()
			state_store.save(self.state, self.path)
		end)
	)
end

function Session:close()
	self:save()
	state_store.prune_snapshots(self.changeset, self.state)
end

return M
