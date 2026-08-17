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

---Collapse a line to its meaning: indent becomes a depth count, trailing
---whitespace disappears. Blank lines return nil and drop out of the key.
---
---Depth counts tabs as one level and every two spaces as one, which is stable
---for any file that indents consistently — the only case that matters, since a
---hunk's lines all come from the same file.
---@param line string
---@return string|nil
local function normalize(line)
	local indent, rest = line:match("^([ \t]*)(.-)%s*$")
	if rest == "" then
		return nil
	end

	local tabs = select(2, indent:gsub("\t", ""))
	local spaces = select(2, indent:gsub(" ", ""))

	return (tabs + math.floor(spaces / 2)) .. "\1" .. rest
end

M.normalize_line = normalize

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

	local normalized = {}
	for _, l in ipairs(post) do
		local n = normalize(l)
		if n then
			normalized[#normalized + 1] = n
		end
	end

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
