---Deciding whether a hunk is one you have already read.
---
---Three questions, asked in order of confidence:
---
---  1. Is this exactly what you approved?            → reviewed
---  2. Is it the same code, differently spaced?      → reviewed, re-anchored
---  3. Does it descend from something you approved?  → stale
---
---and otherwise you have never seen it.
---
---Step 3 leans on the one coordinate system that holds still. New-side line
---numbers move every time the agent touches the file, but every hunk in a
---review is a diff against the *same base revision*, so its old-side range is
---a fixed address. Two hunks whose old-side ranges overlap are looking at the
---same region of the base — which makes the newer one the descendant of the
---older. When the base itself moves, that reasoning is void and this falls
---back to hashes alone.
---
---The bias throughout is toward `stale` over `reviewed`. A hunk wrongly marked
---unread costs you seconds; a hunk wrongly marked reviewed costs you the trust
---that makes the tool worth using.
local M = {}

---@alias draven.HunkStatus "reviewed"|"stale"|"unread"

---Inclusive base-side span of a hunk or mark. A pure insertion has no lines on
---the old side, so it collapses to the single point it was inserted at.
---@param start integer
---@param count integer
---@return integer first
---@return integer last
function M.span(start, count)
	if count <= 0 then
		return start, start
	end
	return start, start + count - 1
end

---How many base lines two spans share. Adjacency is not overlap.
---@return integer
function M.overlap(a_start, a_count, b_start, b_count)
	local a_first, a_last = M.span(a_start, a_count)
	local b_first, b_last = M.span(b_start, b_count)

	local first = math.max(a_first, b_first)
	local last = math.min(a_last, b_last)

	return math.max(0, last - first + 1)
end

---@param hunk draven.Hunk
---@param marks draven.MarkRecord[] # marks recorded for this hunk's file
---@param opts? { base_stable?: boolean }
---@return draven.HunkStatus status
---@return draven.MarkRecord|nil origin # what it descends from, when stale
function M.classify(hunk, marks, opts)
	opts = opts or {}

	if not marks or #marks == 0 then
		return "unread", nil
	end

	-- 1. Byte-for-byte what you approved.
	for _, mark in ipairs(marks) do
		if mark.content_hash == hunk.content_hash then
			return "reviewed", mark
		end
	end

	-- 2. Reindented or reflowed, but saying the same thing.
	for _, mark in ipairs(marks) do
		if mark.anchor_key and mark.anchor_key == hunk.anchor_key then
			return "reviewed", mark
		end
	end

	-- 3. Only meaningful while the base revision is the one the marks were
	-- made against.
	if opts.base_stable == false then
		return "unread", nil
	end

	local origin, best = nil, 0
	for _, mark in ipairs(marks) do
		if mark.old_start then
			local shared =
				M.overlap(mark.old_start, mark.old_count or 0, hunk.old_start, hunk.old_count)
			if shared > best then
				origin, best = mark, shared
			end
		end
	end

	if origin then
		return "stale", origin
	end

	return "unread", nil
end

return M
