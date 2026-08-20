---The changeset panel.
---
---A normal buffer with its own filetype, so window navigation, search and your
---own mappings all behave. It owns no state beyond what it is told to draw.
local config = require("draven.config")
local finding_mod = require("draven.finding")

local M = {}

---nvim-web-devicons if it happens to be installed. Resolved once, and the
---panel reads the same without it.
local devicons
local function icon_for(path)
	if not config.options.ui.panel.icons then
		return nil, nil
	end
	if devicons == nil then
		local ok, mod = pcall(require, "nvim-web-devicons")
		devicons = ok and mod or false
	end
	if not devicons then
		return nil, nil
	end

	local name = vim.fn.fnamemodify(path, ":t")
	return devicons.get_icon(name, vim.fn.fnamemodify(name, ":e"), { default = true })
end

---A bar that reads at a glance, unlike a bare percentage.
---@param done integer
---@param total integer
---@param cells integer
---@return string
local function progress_bar(done, total, cells)
	local filled = total > 0 and math.floor((done / total) * cells + 0.5) or cells
	return string.rep("▰", filled) .. string.rep("▱", cells - filled)
end

M.ns = vim.api.nvim_create_namespace("draven.panel")

---@class draven.PanelEntry
---@field kind "chrome"|"dir"|"file"|"finding"
---@field dir string|nil
---@field file draven.File|nil
---@field finding draven.Finding|nil

---@class draven.Panel
---@field bufnr integer
---@field entries table<integer, draven.PanelEntry>
---@field collapsed table<string, boolean>
local Panel = {}
Panel.__index = Panel

M.BUFNAME = "draven://changeset"

---Buffer names must be unique, and a panel from an earlier review can outlive
---its window. Clear the name out of the way before claiming it.
local function drop_stale_panel()
	for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_get_name(bufnr) == M.BUFNAME then
			pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
		end
	end
end

---@return draven.Panel
function M.new()
	drop_stale_panel()

	local bufnr = vim.api.nvim_create_buf(false, true)

	vim.bo[bufnr].buftype = "nofile"
	vim.bo[bufnr].bufhidden = "hide"
	vim.bo[bufnr].swapfile = false
	vim.bo[bufnr].filetype = "draven-panel"
	vim.bo[bufnr].modifiable = false
	pcall(vim.api.nvim_buf_set_name, bufnr, M.BUFNAME)

	return setmetatable({ bufnr = bufnr, entries = {}, collapsed = {} }, Panel)
end

---@param status "reviewed"|"partial"|"stale"|"unread"|"ignored"|"empty"
---@return string glyph
---@return string highlight
local function status_mark(status)
	local signs = config.options.ui.signs

	if status == "reviewed" then
		return signs.reviewed, "DravenPanelReviewed"
	elseif status == "stale" then
		return signs.stale, "DravenPanelStale"
	elseif status == "partial" then
		return signs.partial, "DravenPanelPartial"
	elseif status == "ignored" then
		return signs.ignored, "DravenPanelIgnored"
	elseif status == "empty" then
		return "·", "DravenPanelIgnored"
	end

	return signs.unread, "DravenPanelUnread"
end

---@param name string
---@param budget integer
---@return string
local function fit(name, budget)
	if vim.fn.strdisplaywidth(name) <= budget then
		return name
	end
	-- Keep the tail: extensions and disambiguating suffixes live there.
	return "…" .. vim.fn.strcharpart(name, vim.fn.strchars(name) - budget + 1)
end

---@param session draven.Session
---@param active_path string|nil
function Panel:render(session, active_path)
	local width = config.options.ui.panel.width
	local cs = session.changeset

	local lines, entries, marks = {}, {}, {}

	local function put(text, entry)
		lines[#lines + 1] = text
		entries[#lines] = entry
		return #lines
	end

	local function mark(lnum, col, len, group)
		marks[#marks + 1] = { lnum = lnum, col = col, len = len, group = group }
	end

	-- Header ------------------------------------------------------------
	local signs = config.options.ui.signs

	local scope
	if cs.revspec.kind == "range" then
		scope = cs.revspec.arg
	elseif cs.unborn then
		scope = "working tree · no commits"
	else
		scope = ("working tree ← %s"):format(cs.revspec.base)
	end

	-- Name and scope share a line: the panel is narrow, and two lines of
	-- chrome before any content is a line too many.
	local head = (" draven  %s"):format(fit(scope, math.max(4, width - 10)))
	local head_line = put(head, { kind = "chrome" })
	mark(head_line, 1, 6, "DravenPanelTitle")
	mark(head_line, 9, #head - 9, "DravenPanelBase")

	local reviewed, total, stale = session:progress()
	local percent = total > 0 and math.floor(reviewed / total * 100) or 100

	local bar = progress_bar(reviewed, total, 12)
	local tally = ("%d/%d"):format(reviewed, total)
	local gap = math.max(1, width - 2 - vim.fn.strdisplaywidth(bar) - #tally - 5)
	local bar_line = put(
		(" %s%s%s %3d%%"):format(bar, string.rep(" ", gap), tally, percent),
		{ kind = "chrome" }
	)
	mark(bar_line, 1, #bar, "DravenPanelProgress")
	mark(bar_line, 1 + #bar + gap, #tally, "DravenPanelCount")

	-- Badges for the two things that want acting on, side by side.
	local badges, badge_marks = " ", {}
	if #session:findings({ unresolved_only = true }) > 0 then
		local n = #session:findings({ unresolved_only = true })
		badge_marks[#badge_marks + 1] = { col = #badges, len = 0, group = "DravenFindingBlocking" }
		local text = ("! %d finding%s"):format(n, n == 1 and "" or "s")
		badge_marks[#badge_marks].len = #text
		badges = badges .. text .. "   "
	end
	if stale > 0 then
		local text = ("%s %d changed"):format(signs.stale, stale)
		badge_marks[#badge_marks + 1] = { col = #badges, len = #text, group = "DravenPanelStale" }
		badges = badges .. text
	end
	if #badge_marks > 0 then
		local lnum = put(badges:gsub("%s+$", ""), { kind = "chrome" })
		for _, b in ipairs(badge_marks) do
			mark(lnum, b.col, b.len, b.group)
		end
	end

	local rule = put(" " .. string.rep("─", math.max(1, width - 2)), { kind = "chrome" })
	mark(rule, 1, width - 2, "DravenPanelRule")

	-- Files ---------------------------------------------------------------
	-- Knowing which file ends its directory is what lets the guides close.
	local last_in_dir = {}
	for index, file in ipairs(cs.files) do
		local dir = vim.fn.fnamemodify(file.path, ":h")
		last_in_dir[dir == "." and "./" or dir .. "/"] = index
	end

	local current_dir = nil

	for index, file in ipairs(cs.files) do
		local dir = vim.fn.fnamemodify(file.path, ":h")
		if dir == "." then
			dir = "./"
		else
			dir = dir .. "/"
		end

		if dir ~= current_dir then
			current_dir = dir
			local arrow = self.collapsed[dir] and "▸" or "▾"
			local text = (" %s %s"):format(arrow, fit(dir, width - 4))
			local lnum = put(text, { kind = "dir", dir = dir })
			mark(lnum, 1, #text, "DravenPanelDir")
		end

		if not self.collapsed[dir] then
			local status = session:file_state(file)
			local glyph, glyph_hl = status_mark(status)

			local name = vim.fn.fnamemodify(file.path, ":t")
			if file.old_path then
				name = ("%s ← %s"):format(name, vim.fn.fnamemodify(file.old_path, ":t"))
			end

			local count
			if file.ignored then
				count = "skip"
			elseif file.binary then
				count = "bin"
			elseif #file.hunks == 0 then
				count = "—"
			else
				local done, all = session:file_progress(file)
				count = ("%d/%d"):format(done, all)
			end

			local _, unresolved = session:finding_counts(file.path)
			local flag = unresolved > 0 and ("!%d "):format(unresolved) or ""
			count = flag .. count

			local guide = last_in_dir[dir] == index and " └ " or " │ "
			local icon, icon_hl = icon_for(file.path)
			local icon_cell = icon and (icon .. " ") or ""

			local prefix = ("%s%s %s"):format(guide, glyph, icon_cell)
			local prefix_w = vim.fn.strdisplaywidth(prefix)

			local budget = width - prefix_w - vim.fn.strdisplaywidth(count) - 2
			name = fit(name, math.max(6, budget))

			local pad = math.max(
				1,
				width - prefix_w - vim.fn.strdisplaywidth(name) - vim.fn.strdisplaywidth(count) - 1
			)
			local text = ("%s%s%s%s"):format(prefix, name, string.rep(" ", pad), count)

			local lnum = put(text, { kind = "file", file = file })
			mark(lnum, 0, #guide, "DravenPanelGuide")
			mark(lnum, #guide, #glyph, glyph_hl)

			if icon and icon_hl then
				mark(lnum, #guide + #glyph + 1, #icon, icon_hl)
			end

			local name_col = #prefix
			mark(lnum, name_col, #name, file.ignored and "DravenPanelIgnored" or "DravenPanelFile")
			local count_col = name_col + #name + pad
			if #flag > 0 then
				mark(lnum, count_col, #flag, "DravenFindingBlocking")
			end
			mark(lnum, count_col + #flag, #count - #flag, "DravenPanelCount")

			if active_path and file.path == active_path then
				marks[#marks + 1] = { lnum = lnum, line_hl = "DravenPanelActive" }
			end
		end
	end

	local orphans = {}
	for _, item in ipairs(session:findings()) do
		if item.state == "orphaned" then
			orphans[#orphans + 1] = item
		end
	end

	if #orphans > 0 then
		local title = (" ⚠ orphaned findings · %d"):format(#orphans)
		local shown = fit(title, width)
		local lnum = put(shown, { kind = "chrome" })
		mark(lnum, 1, #shown - 1, "DravenFindingQuestion")

		for _, item in ipairs(orphans) do
			local location = ("%s:%d"):format(item.path, item.last_lnum or 1)
			local text = "   " .. fit(location .. " · " .. finding_mod.headline(item), width - 3)
			local row = put(text, { kind = "finding", finding = item })
			mark(
				row,
				3,
				#text - 3,
				item.resolved and "DravenFindingResolved" or "DravenFindingQuestion"
			)
		end
	end

	if #cs.files == 0 then
		local lnum = put("  nothing to review", { kind = "chrome" })
		mark(lnum, 0, 20, "DravenPanelHint")
	end

	-- Commit --------------------------------------------------------------
	self.entries = entries

	vim.bo[self.bufnr].modifiable = true
	vim.api.nvim_buf_set_lines(self.bufnr, 0, -1, false, lines)
	vim.bo[self.bufnr].modifiable = false

	vim.api.nvim_buf_clear_namespace(self.bufnr, M.ns, 0, -1)
	for _, m in ipairs(marks) do
		if m.line_hl then
			vim.api.nvim_buf_set_extmark(self.bufnr, M.ns, m.lnum - 1, 0, {
				line_hl_group = m.line_hl,
				priority = 90,
			})
		elseif m.len > 0 then
			pcall(vim.api.nvim_buf_set_extmark, self.bufnr, M.ns, m.lnum - 1, m.col, {
				end_col = m.col + m.len,
				hl_group = m.group,
				priority = 100,
			})
		end
	end
end

---@param lnum integer
---@return draven.PanelEntry|nil
function Panel:entry_at(lnum)
	return self.entries[lnum]
end

---@param dir string
---@return integer|nil
function Panel:line_of_dir(dir)
	for lnum, entry in pairs(self.entries) do
		if entry.kind == "dir" and entry.dir == dir then
			return lnum
		end
	end
	return nil
end

---@param path string
---@return integer|nil
function Panel:line_of(path)
	for lnum, entry in pairs(self.entries) do
		if entry.kind == "file" and entry.file.path == path then
			return lnum
		end
	end
	return nil
end

---@param dir string
---@param collapsed? boolean # omit to toggle
function Panel:toggle_dir(dir, collapsed)
	if collapsed == nil then
		collapsed = not self.collapsed[dir]
	end
	self.collapsed[dir] = collapsed or nil
end

---Collapse or expand every directory at once.
---@param session draven.Session
---@param collapsed boolean
function Panel:set_all(session, collapsed)
	self.collapsed = {}
	if not collapsed then
		return
	end

	for _, file in ipairs(session.changeset.files) do
		local dir = vim.fn.fnamemodify(file.path, ":h")
		self.collapsed[dir == "." and "./" or dir .. "/"] = true
	end
end

---The directory a panel line belongs to, whether it is the header or a file
---underneath it.
---@param lnum integer
---@return string|nil
function Panel:dir_at(lnum)
	local entry = self.entries[lnum]
	if not entry then
		return nil
	end
	if entry.kind == "dir" then
		return entry.dir
	end
	if entry.kind == "file" then
		local dir = vim.fn.fnamemodify(entry.file.path, ":h")
		return dir == "." and "./" or dir .. "/"
	end
	return nil
end

M.Panel = Panel

return M
