---A live review: a changeset joined to its persisted marks.
---
---Everything the UI needs to answer "what is left to read" lives here, and
---nothing in this file touches a window or a buffer.
local state_store = require("draven.state")

---@class draven.Session
---@field changeset draven.Changeset
---@field state draven.State
---@field path string # where the state is persisted
---@field order draven.OrderEntry[] # every reviewable hunk, in review order
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
		_save_timer = nil,
	}, Session)

	self:reindex()
	return self
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
end

---Swap in a freshly built changeset, keeping every mark. Marks are keyed by
---content, so they survive this without any remapping.
---@param cs draven.Changeset
function Session:update(cs)
	self.changeset = cs
	self:reindex()
end

--- Marks ---------------------------------------------------------------------

---@param hunk draven.Hunk
---@return boolean
function Session:is_reviewed(hunk)
	return self.state.reviewed[hunk.content_hash] ~= nil
end

---@param hunk draven.Hunk
---@return "reviewed"|"unread"
function Session:hunk_state(hunk)
	return self:is_reviewed(hunk) and "reviewed" or "unread"
end

---@param hunk draven.Hunk
---@param reviewed boolean
function Session:mark(hunk, reviewed)
	if reviewed then
		self.state.reviewed[hunk.content_hash] = { at = os.time(), path = hunk.path }
	else
		self.state.reviewed[hunk.content_hash] = nil
	end
	self:save_soon()
end

---@param file draven.File
---@param reviewed boolean
function Session:mark_file(file, reviewed)
	for _, hunk in ipairs(file.hunks) do
		if reviewed then
			self.state.reviewed[hunk.content_hash] = { at = os.time(), path = hunk.path }
		else
			self.state.reviewed[hunk.content_hash] = nil
		end
	end
	self:save_soon()
end

---@param reviewed boolean
function Session:mark_all(reviewed)
	for _, entry in ipairs(self.order) do
		if reviewed then
			self.state.reviewed[entry.hunk.content_hash] = {
				at = os.time(),
				path = entry.hunk.path,
			}
		else
			self.state.reviewed[entry.hunk.content_hash] = nil
		end
	end
	self:save_soon()
end

--- Progress ------------------------------------------------------------------

---@return integer reviewed
---@return integer total
function Session:progress()
	local reviewed = 0
	for _, entry in ipairs(self.order) do
		if self:is_reviewed(entry.hunk) then
			reviewed = reviewed + 1
		end
	end
	return reviewed, #self.order
end

---@param file draven.File
---@return integer reviewed
---@return integer total
function Session:file_progress(file)
	local reviewed = 0
	for _, hunk in ipairs(file.hunks) do
		if self:is_reviewed(hunk) then
			reviewed = reviewed + 1
		end
	end
	return reviewed, #file.hunks
end

---@param file draven.File
---@return "reviewed"|"partial"|"unread"|"ignored"|"empty"
function Session:file_state(file)
	if file.ignored then
		return "ignored"
	end
	if #file.hunks == 0 then
		return "empty"
	end

	local reviewed, total = self:file_progress(file)
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

---Walk from `from` looking for an unread hunk, wrapping around once.
---@param from integer|nil # position to start after (or before, going backwards)
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
		if not self:is_reviewed(entry.hunk) then
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
	local hunk_mod = require("draven.core.hunk")

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
	local hunk_mod = require("draven.core.hunk")
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
end

return M
