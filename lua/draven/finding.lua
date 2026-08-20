---Findings: the notes you leave for whoever fixes this — usually the agent.
---
---A finding is anchored to a *line of code*, not a line number, for the same
---reason marks are content-addressed: the agent is about to rewrite the file
---and every number in it will move. Each one remembers the hunk it was made
---in, the text of the line it points at, and where that hunk sat on the base
---revision. Re-anchoring tries those in order, and when none of them land the
---finding is orphaned rather than silently pointed at the wrong line.
local anchor = require("draven.core.anchor")
local hunk_mod = require("draven.core.hunk")

local M = {}

M.SEVERITIES = { "blocking", "question", "nit" }

---@alias draven.Severity "blocking"|"question"|"nit"
---@alias draven.FindingState "anchored"|"moved"|"orphaned"

---@class draven.Finding
---@field id string
---@field path string
---@field severity draven.Severity
---@field body string
---@field resolved boolean
---@field collapsed boolean|nil
---@field created_at integer
---@field updated_at integer
---@field hunk_hash string # content_hash of the hunk it was written against
---@field hunk_old_start integer|nil # base-side address of that hunk
---@field hunk_old_count integer|nil
---@field offset integer # 1-based index into the hunk's post-image
---@field span integer # how many lines it covers
---@field line_text string # the anchored line, verbatim
---@field last_lnum integer # where it was last seen, for orphan display
---@field lnum integer|nil # resolved at load time; nil when orphaned
---@field state draven.FindingState # resolved at load time

---@param severity string|nil
---@return draven.Severity
function M.normalize_severity(severity)
	for _, known in ipairs(M.SEVERITIES) do
		if severity == known then
			return known
		end
	end
	return M.SEVERITIES[1]
end

---@param severity draven.Severity
---@return draven.Severity
function M.next_severity(severity)
	for i, known in ipairs(M.SEVERITIES) do
		if known == severity then
			return M.SEVERITIES[(i % #M.SEVERITIES) + 1]
		end
	end
	return M.SEVERITIES[1]
end

---@return string
local function new_id()
	return ("%x-%x"):format(os.time(), math.random(0, 0xffffff))
end

---Build a finding anchored to `lnum` in `hunk`.
---@param hunk draven.Hunk
---@param lnum integer
---@param opts { body: string, severity: draven.Severity, span?: integer }
---@return draven.Finding|nil
function M.create(hunk, lnum, opts)
	local offset = hunk_mod.offset_of(hunk.lines, lnum)
	if not offset then
		return nil
	end

	local image = hunk_mod.post_image(hunk.lines)

	return {
		id = new_id(),
		path = hunk.path,
		severity = M.normalize_severity(opts.severity),
		body = opts.body,
		resolved = false,
		-- Keep the source compact until the reviewer asks for the full body.
		collapsed = true,
		created_at = os.time(),
		updated_at = os.time(),
		hunk_hash = hunk.content_hash,
		hunk_old_start = hunk.old_start,
		hunk_old_count = hunk.old_count,
		offset = offset,
		span = math.max(1, opts.span or 1),
		line_text = image[offset] or "",
		last_lnum = lnum,
	}
end

---@param a string
---@param b string
---@return boolean
local function same_line(a, b)
	return a == b or vim.trim(a) == vim.trim(b)
end

---Find `text` in a hunk's post-image, preferring a position near `hint`.
---@param image string[]
---@param text string
---@param hint integer|nil
---@return integer|nil offset
local function locate(image, text, hint)
	local matches = {}
	for i, line in ipairs(image) do
		if same_line(line, text) then
			matches[#matches + 1] = i
		end
	end

	if #matches == 0 then
		return nil
	end
	if #matches == 1 then
		return matches[1]
	end

	-- Repeated lines (a lone `}` is the usual culprit): take the one closest
	-- to where the finding used to sit.
	local best, distance = matches[1], math.huge
	for _, i in ipairs(matches) do
		local d = math.abs(i - (hint or 1))
		if d < distance then
			best, distance = i, d
		end
	end
	return best
end

---Re-anchor a finding against the current state of its file.
---
---Mutates and returns the finding with `lnum` and `state` filled in.
---@param finding draven.Finding
---@param file draven.File|nil
---@param opts? { base_stable?: boolean }
---@return draven.Finding
function M.reanchor(finding, file, opts)
	opts = opts or {}

	finding.lnum = nil
	finding.state = "orphaned"

	if not file then
		return finding
	end

	-- 1. The hunk it was written against is still exactly that hunk.
	for _, hunk in ipairs(file.hunks) do
		if hunk.content_hash == finding.hunk_hash then
			local lnums = hunk_mod.post_lnums(hunk.lines)
			local lnum = lnums[finding.offset]
			if lnum then
				finding.lnum, finding.state = lnum, "anchored"
				finding.last_lnum = lnum
				return finding
			end
		end
	end

	-- 2. That hunk was rewritten. Look for the line inside whatever now
	-- covers the same region of the base revision.
	if opts.base_stable ~= false and finding.hunk_old_start then
		local candidate, best = nil, 0
		for _, hunk in ipairs(file.hunks) do
			local shared = anchor.overlap(
				finding.hunk_old_start,
				finding.hunk_old_count or 0,
				hunk.old_start,
				hunk.old_count
			)
			if shared > best then
				candidate, best = hunk, shared
			end
		end

		if candidate then
			local image = hunk_mod.post_image(candidate.lines)
			local offset = locate(image, finding.line_text, finding.offset)
			if offset then
				local lnum = hunk_mod.post_lnums(candidate.lines)[offset]
				if lnum then
					finding.lnum, finding.state = lnum, "moved"
					finding.offset, finding.last_lnum = offset, lnum
					return finding
				end
			end
		end
	end

	-- 3. Last resort: the line may have moved to a different hunk entirely.
	-- Only trust it when the whole file offers exactly one candidate.
	local found_lnum, found_offset, count = nil, nil, 0
	for _, hunk in ipairs(file.hunks) do
		local image = hunk_mod.post_image(hunk.lines)
		for i, line in ipairs(image) do
			if same_line(line, finding.line_text) then
				count = count + 1
				found_lnum = hunk_mod.post_lnums(hunk.lines)[i]
				found_offset = i
			end
		end
	end

	if count == 1 and found_lnum then
		finding.lnum, finding.state = found_lnum, "moved"
		finding.offset, finding.last_lnum = found_offset, found_lnum
	end

	return finding
end

---@param finding draven.Finding
---@return string # first line of the body, for one-line displays
function M.headline(finding)
	local first = vim.split(finding.body or "", "\n", { plain = true })[1] or ""
	first = vim.trim(first)
	return first ~= "" and first or "(no description)"
end

---The line used to display and operate on a finding. Orphans deliberately do
---not regain an anchor, but their last known line is still a useful place to
---show the warning when that file remains in the changeset.
---@param finding draven.Finding
---@param line_count integer
---@return integer|nil
function M.display_lnum(finding, line_count)
	if finding.lnum then
		return math.max(1, math.min(finding.lnum, line_count))
	end
	if finding.state == "orphaned" and finding.last_lnum then
		return math.max(1, math.min(finding.last_lnum, line_count))
	end
	return nil
end

---Sort key: blocking before question before nit, then by file and line.
---@param a draven.Finding
---@param b draven.Finding
---@return boolean
function M.before(a, b)
	local rank = { blocking = 1, question = 2, nit = 3 }
	local ra, rb = rank[a.severity] or 9, rank[b.severity] or 9

	if ra ~= rb then
		return ra < rb
	end
	if a.path ~= b.path then
		return a.path < b.path
	end
	return (a.lnum or a.last_lnum or 0) < (b.lnum or b.last_lnum or 0)
end

return M
