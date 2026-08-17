---A live review: a changeset joined to its persisted marks.
---
---Everything the UI needs to answer "what is left to read" lives here, and
---nothing in this file touches a window or a buffer.
local anchor = require("draven.core.anchor")
local config = require("draven.config")
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
		log.info(("base revision moved — %d mark%s can no longer be traced to a rewrite"):format(
			dropped,
			dropped == 1 and "" or "s"
		))
		self:save_soon()
	end
end

---Group marks by the file they were made in, and classify every hunk.
function Session:_reclassify()
	self._by_path = {}

	for hash, record in pairs(self.state.reviewed) do
		-- Older records were keyed only; make the key reachable from the value.
		record.content_hash = record.content_hash or hash

		local list = self._by_path[record.path]
		if not list then
			list = {}
			self._by_path[record.path] = list
		end
		list[#list + 1] = record
	end

	self._status = {}
	for _, entry in ipairs(self.order) do
		local status, origin = anchor.classify(entry.hunk, self._by_path[entry.hunk.path], {
			base_stable = self.base_stable,
		})
		self._status[entry.hunk.id] = { status = status, origin = origin }
	end
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
	local status = anchor.classify(hunk, self._by_path[hunk.path], {
		base_stable = self.base_stable,
	})
	return status
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
