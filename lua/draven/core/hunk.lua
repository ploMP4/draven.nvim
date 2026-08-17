---Hunk model and content addressing.
---
---This is where the thesis lives. Review state is keyed to what a hunk *says*,
---not where it sits, so an edit elsewhere in the file cannot silently
---invalidate a mark and a moved hunk can still be recognised.
---
---Two keys per hunk, because one is not enough:
---
---  `content_hash`  exact post-image. Equal means definitely unchanged.
---  `anchor_key`    whitespace-normalised post-image. Survives reindentation
---                  and blank-line churn, and is what a relocation pass
---                  matches on when the exact hash misses.
---
---When neither matches, the hunk is stale. That direction of error is the safe
---one: a false "unread" costs seconds, a false "reviewed" costs trust.
local M = {}

---@class draven.Hunk
---@field id string # addresses this hunk within one changeset only
---@field index integer # 1-based position within its file
---@field path string
---@field old_start integer
---@field old_count integer
---@field new_start integer
---@field new_count integer
---@field section string
---@field lines draven.DiffLine[]
---@field added integer
---@field removed integer
---@field content_hash string
---@field anchor_key string

---Lines as they exist after the change.
---@param lines draven.DiffLine[]
---@return string[]
function M.post_image(lines)
	local out = {}
	for _, l in ipairs(lines) do
		if l.kind ~= "delete" then
			out[#out + 1] = l.text
		end
	end
	return out
end

---Lines as they existed before the change.
---@param lines draven.DiffLine[]
---@return string[]
function M.pre_image(lines)
	local out = {}
	for _, l in ipairs(lines) do
		if l.kind ~= "add" then
			out[#out + 1] = l.text
		end
	end
	return out
end

---Tabs are compared against spaces at this width. It only has to be consistent,
---not correct: the indent unit is derived per hunk, so the choice cancels out.
local TAB_WIDTH = 4

---@param indent string
---@return integer
local function indent_width(indent)
	local width = 0
	for i = 1, #indent do
		width = width + (indent:sub(i, i) == "\t" and TAB_WIDTH or 1)
	end
	return width
end

---@return integer
local function gcd(a, b)
	while b ~= 0 do
		a, b = b, a % b
	end
	return a
end

---Collapse lines to their meaning: trailing whitespace disappears, blank lines
---drop out, and leading indent becomes a *nesting level* rather than a width.
---
---The level is the indent width divided by the hunk's own indent unit — the
---GCD of the widths it actually uses. That is what makes the key survive
---reformatting: the same block indented with tabs, two spaces or four spaces
---all reduce to the same 0/1/2 ladder, while genuinely different nesting still
---reads as different.
---
---The trade-off: deriving the unit from the hunk means *relative* structure is
---preserved but absolute depth is not, so a two-line block at one level and
---the same block at two levels look identical. Anything with real structure
---to it disambiguates, and the fallback for a miss is `stale` — a delta you
---glance at — rather than a wrong `reviewed`.
---@param lines string[]
---@return string[]
function M.normalize(lines)
	local parsed, unit = {}, 0

	for _, line in ipairs(lines) do
		local indent, rest = line:match("^([ \t]*)(.-)%s*$")
		if rest ~= "" then
			local width = indent_width(indent)
			parsed[#parsed + 1] = { width = width, rest = rest }
			if width > 0 then
				unit = gcd(unit, width)
			end
		end
	end

	if unit == 0 then
		unit = 1
	end

	local out = {}
	for i, entry in ipairs(parsed) do
		out[i] = math.floor(entry.width / unit) .. "\1" .. entry.rest
	end

	return out
end

---@param path string
---@param body string
---@return string
function M.hash(path, body)
	return vim.fn.sha256(path .. "\0" .. body)
end

---@param path string
---@param raw draven.RawHunk
---@param index integer
---@return draven.Hunk
function M.build(path, raw, index)
	local added, removed = 0, 0
	for _, l in ipairs(raw.lines) do
		if l.kind == "add" then
			added = added + 1
		elseif l.kind == "delete" then
			removed = removed + 1
		end
	end

	local post = M.post_image(raw.lines)
	local normalized = M.normalize(post)

	return {
		id = ("%s#%d"):format(path, index),
		index = index,
		path = path,
		old_start = raw.old_start,
		old_count = raw.old_count,
		new_start = raw.new_start,
		new_count = raw.new_count,
		section = raw.section or "",
		lines = raw.lines,
		added = added,
		removed = removed,
		content_hash = M.hash(path, table.concat(post, "\n")),
		anchor_key = M.hash(path, table.concat(normalized, "\n")),
	}
end

---Range of buffer lines this hunk covers in the post-image file.
---Returns 0, 0 for a pure deletion, which occupies no lines.
---@param h draven.Hunk
---@return integer first
---@return integer last
function M.new_range(h)
	if h.new_count == 0 then
		return 0, 0
	end
	return h.new_start, h.new_start + h.new_count - 1
end

return M
