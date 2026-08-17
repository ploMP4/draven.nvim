---The v1→v2 delta.
---
---On a stale hunk, this answers the question that actually matters after you
---send findings back: *what did the agent change against the version I
---approved?* — rather than making you re-read the whole hunk from scratch.
local config = require("draven.config")
local hunk_mod = require("draven.core.hunk")
local log = require("draven.util.log")

local M = {}

M.ns = vim.api.nvim_create_namespace("draven.delta")

---@type integer|nil
local open_win = nil

---@param seconds integer
---@return string
local function ago(seconds)
	if seconds < 60 then
		return "just now"
	elseif seconds < 3600 then
		local n = math.floor(seconds / 60)
		return ("%d minute%s ago"):format(n, n == 1 and "" or "s")
	elseif seconds < 86400 then
		local n = math.floor(seconds / 3600)
		return ("%d hour%s ago"):format(n, n == 1 and "" or "s")
	end

	local n = math.floor(seconds / 86400)
	return ("%d day%s ago"):format(n, n == 1 and "" or "s")
end

---@param before string[]
---@param after string[]
---@return string[] lines
---@return integer added
---@return integer removed
local function unified(before, after)
	local a = #before > 0 and (table.concat(before, "\n") .. "\n") or ""
	local b = #after > 0 and (table.concat(after, "\n") .. "\n") or ""

	local raw = vim.diff(a, b, {
		result_type = "unified",
		ctxlen = 3,
		algorithm = "histogram",
	})

	local lines, added, removed = {}, 0, 0

	for _, line in ipairs(vim.split(raw or "", "\n", { plain = true })) do
		if line ~= "" then
			lines[#lines + 1] = line
			local marker = line:sub(1, 1)
			if marker == "+" then
				added = added + 1
			elseif marker == "-" then
				removed = removed + 1
			end
		end
	end

	return lines, added, removed
end

function M.close()
	if open_win and vim.api.nvim_win_is_valid(open_win) then
		vim.api.nvim_win_close(open_win, true)
	end
	open_win = nil
end

---@param lines string[]
---@param marks table[]
---@param title string
local function float(lines, marks, title)
	M.close()

	local ui = config.options.ui.delta

	local width = 0
	for _, line in ipairs(lines) do
		width = math.max(width, vim.fn.strdisplaywidth(line))
	end
	width = math.max(40, math.min(ui.max_width, width + 2))
	local height = math.max(3, math.min(ui.max_height, #lines))

	local bufnr = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
	vim.bo[bufnr].modifiable = false
	vim.bo[bufnr].buftype = "nofile"
	vim.bo[bufnr].bufhidden = "wipe"
	vim.bo[bufnr].filetype = "draven-delta"

	for _, m in ipairs(marks) do
		pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, m.lnum - 1, 0, {
			line_hl_group = m.group,
			priority = 100,
		})
	end

	open_win = vim.api.nvim_open_win(bufnr, true, {
		relative = "editor",
		width = width,
		height = height,
		row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
		col = math.max(0, math.floor((vim.o.columns - width) / 2)),
		style = "minimal",
		border = ui.border,
		title = " " .. title .. " ",
		title_pos = "center",
	})

	vim.wo[open_win].wrap = false
	vim.wo[open_win].cursorline = false

	for _, lhs in ipairs({ "q", "<Esc>" }) do
		vim.keymap.set("n", lhs, M.close, { buffer = bufnr, nowait = true, silent = true })
	end

	vim.api.nvim_create_autocmd("WinLeave", {
		buffer = bufnr,
		once = true,
		callback = function()
			vim.schedule(M.close)
		end,
	})
end

---Show what changed between the version you approved and what is there now.
---@param session draven.Session
---@param hunk draven.Hunk
function M.open(session, hunk)
	local status = session:hunk_state(hunk)

	if status == "reviewed" then
		log.info("you have already read this, unchanged since")
		return
	end

	local origin = session:origin_of(hunk)
	if status ~= "stale" or not origin then
		log.info("nothing to compare — this hunk is new, not a rewrite")
		return
	end

	local before = session:approved_image(hunk)
	if not before then
		log.warn("no stored snapshot for the version you approved")
		return
	end

	local after = hunk_mod.post_image(hunk.lines)
	local body, added, removed = unified(before, after)

	if #body == 0 then
		log.info("no textual difference — only whitespace or context moved")
		return
	end

	local lines, marks = {}, {}
	local function put(text, group)
		lines[#lines + 1] = text
		if group then
			marks[#marks + 1] = { lnum = #lines, group = group }
		end
	end

	put(
		(" %s  %s · hunk %d"):format(config.options.ui.signs.stale, hunk.path, hunk.index),
		"DravenDeltaHeader"
	)
	put(
		(" approved %s · +%d/-%d since"):format(ago(os.time() - (origin.at or os.time())), added, removed),
		"DravenDeltaMeta"
	)
	put("", nil)

	for _, line in ipairs(body) do
		local marker = line:sub(1, 1)
		if marker == "+" then
			put(line, "DravenDeltaAdd")
		elseif marker == "-" then
			put(line, "DravenDeltaDelete")
		elseif marker == "@" then
			put(line, "DravenDeltaHunk")
		else
			put(line, nil)
		end
	end

	float(lines, marks, "v1 → v2")
end

return M
