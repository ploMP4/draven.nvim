---Getting findings back out.
---
---The output of reviewing agent output is usually a prompt, not a pull request
---comment. So the default export is written to be pasted straight into an
---agent: grouped by severity so the important things are read first, each one
---carrying the file, the line and the code it points at.
local config = require("draven.config")
local finding_mod = require("draven.finding")
local hunk_mod = require("draven.core.hunk")

local M = {}

local HEADINGS = {
	blocking = "Blocking — these must be fixed",
	question = "Questions — explain or fix",
	nit = "Nits — fix if cheap",
}

---A few lines of the file around a finding, for context in the export.
---@param session draven.Session
---@param item draven.Finding
---@return string[] lines
---@return string filetype
local function excerpt(session, item)
	local changeset = require("draven.core.changeset")
	local file = changeset.file(session.changeset, item.path)
	local ft = vim.filetype.match({ filename = item.path }) or ""

	if not file or not item.lnum then
		return { item.line_text }, ft
	end

	for _, hunk in ipairs(file.hunks) do
		local lnums = hunk_mod.post_lnums(hunk.lines)
		local image = hunk_mod.post_image(hunk.lines)

		for i, lnum in ipairs(lnums) do
			if lnum == item.lnum then
				local first = math.max(1, i - 1)
				local last = math.min(#image, i + item.span)
				return vim.list_slice(image, first, last), ft
			end
		end
	end

	return { item.line_text }, ft
end

---@param session draven.Session
---@return string
local function scope(session)
	local cs = session.changeset
	if cs.revspec.kind == "range" then
		return cs.revspec.arg
	end
	return ("working tree against %s"):format(cs.revspec.base)
end

---Findings as markdown, ready to paste into an agent.
---@param session draven.Session
---@param opts? { unresolved_only?: boolean, include_excerpt?: boolean }
---@return string text
---@return integer count
function M.prompt(session, opts)
	opts = vim.tbl_extend("force", { unresolved_only = true, include_excerpt = true }, opts or {})

	local items = session:findings({ unresolved_only = opts.unresolved_only })
	if #items == 0 then
		return "", 0
	end

	local by_severity = { blocking = {}, question = {}, nit = {} }
	for _, item in ipairs(items) do
		table.insert(by_severity[item.severity] or by_severity.blocking, item)
	end

	local out = {}
	local function put(line)
		out[#out + 1] = line
	end

	local reviewed, total = session:progress()
	put(("Code review of %s."):format(scope(session)))
	put("")
	put(("%d of %d hunks read; %d finding%s below."):format(
		reviewed,
		total,
		#items,
		#items == 1 and "" or "s"
	))
	put("Address them in order. Do not change anything else.")

	for _, severity in ipairs(finding_mod.SEVERITIES) do
		local group = by_severity[severity]
		if group and #group > 0 then
			put("")
			put("## " .. HEADINGS[severity])

			for _, item in ipairs(group) do
				put("")

				local where = item.lnum and ("%s:%d"):format(item.path, item.lnum)
					or ("%s (line unknown — the code it referred to has changed)"):format(item.path)
				put(("### %s"):format(where))

				if opts.include_excerpt then
					local lines, ft = excerpt(session, item)
					put("")
					put("```" .. ft)
					for _, line in ipairs(lines) do
						put(line)
					end
					put("```")
				end

				put("")
				put(vim.trim(item.body))
			end
		end
	end

	put("")
	return table.concat(out, "\n"), #items
end

---Findings as a review summary for a human, resolved ones included.
---@param session draven.Session
---@return string
function M.markdown(session)
	local text = M.prompt(session, { unresolved_only = false })
	return text
end

---Load findings into the quickfix list.
---@param session draven.Session
---@param opts? { unresolved_only?: boolean, open?: boolean }
---@return integer count
function M.quickfix(session, opts)
	opts = vim.tbl_extend("force", { unresolved_only = true, open = true }, opts or {})

	local types = { blocking = "E", question = "W", nit = "I" }
	local root = session.changeset.root
	local items = {}

	for _, item in ipairs(session:findings({ unresolved_only = opts.unresolved_only })) do
		local prefix = item.resolved and "[done] " or ""
		if item.state == "orphaned" then
			prefix = prefix .. "[orphaned] "
		end

		items[#items + 1] = {
			filename = root .. "/" .. item.path,
			lnum = item.lnum or item.last_lnum or 1,
			col = 1,
			type = types[item.severity] or "E",
			text = prefix .. finding_mod.headline(item),
		}
	end

	vim.fn.setqflist({}, " ", {
		title = ("draven findings (%s)"):format(scope(session)),
		items = items,
	})

	if opts.open and #items > 0 then
		vim.cmd("botright copen")
	end

	return #items
end

---@param text string
---@return boolean
function M.to_clipboard(text)
	local register = config.options.export.register

	local ok = pcall(vim.fn.setreg, register, text)
	if ok and register ~= '"' then
		pcall(vim.fn.setreg, '"', text)
	end

	return ok
end

return M
