---Diff decoration.
---
---Nothing here writes to a buffer. Added lines get a ranged highlight, deleted
---lines become virtual lines, and review state lives in the sign column — so
---the buffer under all of it stays the real file, with LSP attached, treesitter
---live and every one of your mappings working.
local config = require("draven.config")
local finding_mod = require("draven.finding")
local hunk_mod = require("draven.core.hunk")

local M = {}

M.ns = vim.api.nvim_create_namespace("draven.diff")

---Fold levels per buffer, indexed by line number. `foldexpr` reads these.
---@type table<integer, integer[]>
local fold_levels = {}

---@param bufnr integer
local function line_count(bufnr)
	return vim.api.nvim_buf_line_count(bufnr)
end

---Highlight a run of lines including the end-of-line cell, using one extmark
---rather than one per line.
---@param bufnr integer
---@param first integer # 1-based, inclusive
---@param last integer # 1-based, inclusive
---@param group string
local function highlight_range(bufnr, first, last, group)
	local total = line_count(bufnr)
	if first > total then
		return
	end
	last = math.min(last, total)

	local end_row, end_col
	if last < total then
		end_row, end_col = last, 0
	else
		local text = vim.api.nvim_buf_get_lines(bufnr, last - 1, last, false)[1] or ""
		end_row, end_col = last - 1, #text
	end

	pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, first - 1, 0, {
		end_row = end_row,
		end_col = end_col,
		hl_group = group,
		hl_eol = true,
		priority = 100,
	})
end

local truncate_display

---Render deleted lines as virtual lines.
---
---They open with a gutter that mirrors the real sign column — a spine and a
---`-` — so a removed line is recognisable as one at a glance, not just by a
---background colour that many colorschemes make nearly identical to DiffAdd.
---The text is padded so the background runs the full width.
---@param bufnr integer
---@param lnum integer # anchor line, 1-based
---@param above boolean
---@param texts string[]
---@param width integer
local function virtual_deletions(bufnr, lnum, above, texts, width)
	if #texts == 0 then
		return
	end

	local signs = config.options.ui.signs
	local total = line_count(bufnr)
	lnum = math.max(1, math.min(lnum, total))

	-- Virtual lines begin at the text area, and added lines carry an inline
	-- marker in that same first cell, so the two columns line up.
	local marker = ("%-2s"):format(signs.delete)
	local indent = vim.fn.strdisplaywidth(marker)

	local visible = texts
	local hidden = 0
	local limit = math.max(1, config.options.ui.max_inline_deletions or 8)
	if #texts > limit then
		visible = {}
		for i = 1, limit - 1 do
			visible[#visible + 1] = texts[i]
		end
		hidden = #texts - #visible
	end

	local virt_lines = {}
	for i, text in ipairs(visible) do
		local pad = math.max(0, width - indent - vim.fn.strdisplaywidth(text))
		virt_lines[i] = {
			{ marker, "DravenMarkerDelete" },
			{ text .. string.rep(" ", pad), "DravenDelete" },
		}
	end

	if hidden > 0 then
		local summary = ("… %d more deleted line%s · <leader>rd opens full hunk"):format(
			hidden,
			hidden == 1 and "" or "s"
		)
		virt_lines[#virt_lines + 1] = {
			{ marker, "DravenMarkerDelete" },
			{ truncate_display(summary, math.max(1, width - indent)), "DravenDelete" },
		}
	end

	pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, lnum - 1, 0, {
		virt_lines = virt_lines,
		virt_lines_above = above,
		priority = 100,
	})
end

---Place a sign. The sign column carries review state only; the diff markers
---live inline so they align with the virtual lines that show deletions.
---@param bufnr integer
---@param lnum integer
---@param text string
---@param group string
---@param priority? integer
local function sign(bufnr, lnum, text, group, priority)
	if lnum < 1 or lnum > line_count(bufnr) then
		return
	end

	pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, lnum - 1, 0, {
		sign_text = text,
		sign_hl_group = group,
		priority = priority or 120,
	})
end

---A two-cell marker at the very start of the text, in the same column a
---deleted line's marker occupies.
---@param bufnr integer
---@param lnum integer
---@param text string
---@param group string
local function inline_marker(bufnr, lnum, text, group)
	if lnum < 1 or lnum > line_count(bufnr) then
		return
	end

	pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, lnum - 1, 0, {
		virt_text = { { text, group } },
		virt_text_pos = "inline",
		right_gravity = false,
		priority = 105,
	})
end

---@param status draven.HunkStatus
---@return string glyph
---@return string highlight
local function status_sign(status)
	local signs = config.options.ui.signs

	if status == "reviewed" then
		return signs.reviewed, "DravenSignReviewed"
	elseif status == "stale" then
		return signs.stale, "DravenSignStale"
	end

	return signs.unread, "DravenSignUnread"
end

M.status_sign = status_sign

---@param bufnr integer
---@param hunk draven.Hunk
---@param status draven.HunkStatus
---@param width integer
local function render_hunk(bufnr, hunk, status, width)
	local signs = config.options.ui.signs

	-- Added lines, in runs.
	local add_first, add_last = nil, nil
	-- Deleted lines waiting for something to hang off.
	local deletes = {}
	local last_seen = nil

	local add_marker = ("%-2s"):format(signs.add)

	local function flush_adds()
		if add_first then
			highlight_range(bufnr, add_first, add_last, "DravenAdd")
			for lnum = add_first, add_last do
				inline_marker(bufnr, lnum, add_marker, "DravenMarkerAdd")
			end
			add_first, add_last = nil, nil
		end
	end

	local function flush_deletes(anchor, above)
		if #deletes > 0 then
			virtual_deletions(bufnr, anchor, above, deletes, width)
			deletes = {}
		end
	end

	for _, line in ipairs(hunk.lines) do
		if line.kind == "delete" then
			flush_adds()
			deletes[#deletes + 1] = line.text
		else
			-- Deletions belong immediately above whatever followed them.
			flush_deletes(line.new_lnum, true)
			last_seen = line.new_lnum

			if line.kind == "add" then
				add_first = add_first or line.new_lnum
				add_last = line.new_lnum
			else
				flush_adds()
			end
		end
	end

	flush_adds()

	if #deletes > 0 then
		if last_seen then
			-- Trailing deletions sit below the last surviving line.
			flush_deletes(last_seen, false)
		else
			-- A hunk with no post-image at all: hang it off the line the diff
			-- says it followed, or above line 1 when it was the file's head.
			local anchor = hunk.new_start
			flush_deletes(math.max(1, anchor), anchor == 0)
		end
	end

	-- Review state down the sign column: the glyph once, then a spine.
	local first, last = hunk_mod.new_range(hunk)
	if first == 0 then
		first = math.max(1, hunk.new_start)
		last = first
	end

	-- The sign column: a coloured bar down every line of the hunk so its
	-- extent and kind read at a glance, with review state in a slot of
	-- its own.
	--
	-- Every line of the hunk gets both signs, blanks included. That is
	-- deliberate: leaving a gap lets another plugin's signs fill it, and
	-- two symbologies in one gutter is what made this confusing to read.
	local kinds = {}
	for _, line in ipairs(hunk.lines) do
		if line.new_lnum and line.kind ~= "delete" then
			kinds[line.new_lnum] = line.kind
		end
	end

	local glyph, glyph_hl = status_sign(status)

	for lnum = first, last do
		if lnum == first then
			sign(bufnr, lnum, glyph, glyph_hl, 140)
		else
			sign(bufnr, lnum, " ", "DravenSignBar", 140)
		end

		local added = kinds[lnum] == "add"
		sign(bufnr, lnum, signs.bar, added and "DravenHunkAdd" or "DravenHunkContext", 130)
	end

	-- Unchanged lines inside the hunk get the same two cells, so the marker
	-- column is straight rather than staggered.
	local blank = string.rep(" ", vim.fn.strdisplaywidth(add_marker))
	for _, line in ipairs(hunk.lines) do
		if line.kind == "context" and line.new_lnum then
			inline_marker(bufnr, line.new_lnum, blank, "DravenMarkerContext")
		end
	end
end

---@param item draven.Finding
---@return string
local function finding_highlight(item)
	if item.resolved then
		return "DravenFindingResolved"
	end
	return ({
		blocking = "DravenFindingBlocking",
		question = "DravenFindingQuestion",
		nit = "DravenFindingNit",
	})[item.severity] or "DravenFindingBlocking"
end

---@param item draven.Finding
---@return string
local function finding_underline(item)
	if item.resolved then
		return "DravenFindingResolvedLine"
	end
	return ({
		blocking = "DravenFindingBlockingLine",
		question = "DravenFindingQuestionLine",
		nit = "DravenFindingNitLine",
	})[item.severity] or "DravenFindingBlockingLine"
end

---@param text string
---@param width integer
---@return string
truncate_display = function(text, width)
	if width <= 0 then
		return ""
	end
	if vim.fn.strdisplaywidth(text) <= width then
		return text
	end

	local suffix = width > 1 and "…" or ""
	local limit = width - vim.fn.strdisplaywidth(suffix)
	local chars, used, take = vim.fn.strchars(text), 0, 0
	for i = 1, chars do
		local char = vim.fn.strcharpart(text, i - 1, 1)
		local char_width = vim.fn.strdisplaywidth(char)
		if used + char_width > limit then
			break
		end
		used = used + char_width
		take = i
	end
	return vim.fn.strcharpart(text, 0, take) .. suffix
end

---@param text string
---@param width integer
---@return string[]
local function wrap_display(text, width)
	width = math.max(1, width)
	if text == "" then
		return { "" }
	end

	local out = {}
	local rest = text
	while rest ~= "" do
		if vim.fn.strdisplaywidth(rest) <= width then
			out[#out + 1] = rest
			break
		end

		local chars, used, take, space = vim.fn.strchars(rest), 0, 0, nil
		for i = 1, chars do
			local char = vim.fn.strcharpart(rest, i - 1, 1)
			local char_width = vim.fn.strdisplaywidth(char)
			if used + char_width > width then
				break
			end
			used = used + char_width
			take = i
			if char:match("%s") then
				space = i
			end
		end

		local split = space and space > 0 and space or math.max(1, take)
		out[#out + 1] = vim.trim(vim.fn.strcharpart(rest, 0, split))
		rest = vim.fn.strcharpart(rest, split):gsub("^%s+", "")
	end

	return out
end

---@param item draven.Finding
---@return string
local function finding_badge(item)
	if item.state == "orphaned" then
		return "⚠ orphaned · " .. item.severity
	end
	if item.resolved then
		return "✓ resolved · " .. item.severity
	end
	return item.severity
end

---@param item draven.Finding
---@param width integer
---@return table[]
local function finding_rows(item, width)
	local hl = finding_highlight(item)
	local badge = finding_badge(item)
	local gutter = "  ▎ "
	local rows = {}

	if item.collapsed then
		local prefix = gutter .. "▸ " .. badge .. " · "
		local available = math.max(1, width - vim.fn.strdisplaywidth(prefix))
		rows[1] = {
			{ gutter .. "▸ " .. badge .. " · ", hl },
			{ truncate_display(finding_mod.headline(item), available), "Comment" },
		}
		return rows
	end

	rows[1] = {
		{ gutter .. "▾ " .. badge, hl },
	}

	local body_width = math.max(1, width - vim.fn.strdisplaywidth(gutter .. "  "))
	local body = vim.split(vim.trim(item.body or ""), "\n", { plain = true })
	for _, line in ipairs(body) do
		for _, wrapped in ipairs(wrap_display(line, body_width)) do
			rows[#rows + 1] = {
				{ gutter, hl },
				{ "  " .. wrapped, "Normal" },
			}
		end
	end

	return rows
end

---Findings underline their source and render as annotations below it. A
---collapsed finding is one compact summary; expanding it always produces a
---separate header and wrapped body, even when the body contains only one line.
---Findings sharing a source line are combined into one virtual block so their
---text never overlaps.
---@param bufnr integer
---@param file draven.File
---@param session draven.Session
---@param width integer
local function render_findings(bufnr, file, session, width)
	local mode = config.options.ui.finding_display
	if mode == false or mode == "none" then
		return
	end

	local total = line_count(bufnr)
	local by_line = {}

	for _, item in ipairs(session:findings({ path = file.path })) do
		local lnum = finding_mod.display_lnum(item, total)
		if lnum then
			by_line[lnum] = by_line[lnum] or {}
			by_line[lnum][#by_line[lnum] + 1] = item
		end
	end

	for lnum, items in pairs(by_line) do
		-- Prefer an unresolved finding for the underline when several share a
		-- line; lists are severity-sorted, so this also picks the strongest.
		local primary
		for _, item in ipairs(items) do
			if item.state ~= "orphaned" and not item.resolved then
				primary = item
				break
			end
		end
		if not primary then
			for _, item in ipairs(items) do
				if item.state ~= "orphaned" then
					primary = item
					break
				end
			end
		end

		if primary then
			local text = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""
			pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, lnum - 1, 0, {
				end_row = lnum - 1,
				end_col = #text,
				hl_group = finding_underline(primary),
				priority = 200,
			})
		end

		local rows, eol = {}, {}
		for _, item in ipairs(items) do
			if mode == "eol" and item.collapsed then
				if #eol > 0 then
					eol[#eol + 1] = { "  ·  ", "Comment" }
				end
				eol[#eol + 1] = {
					("  ▎ ▸ %s · %s"):format(finding_badge(item), finding_mod.headline(item)),
					finding_highlight(item),
				}
			else
				vim.list_extend(rows, finding_rows(item, width))
			end
		end

		if #eol > 0 then
			pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, lnum - 1, 0, {
				virt_text = eol,
				virt_text_pos = "eol",
				priority = 130,
			})
		end

		if #rows > 0 then
			pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, lnum - 1, 0, {
				virt_lines = rows,
				virt_lines_above = mode == "above",
				priority = 130,
			})
		end
	end
end

---Fold everything more than `fold_context` lines away from a hunk.
---@param bufnr integer
---@param file draven.File
local function compute_folds(bufnr, file)
	local total = line_count(bufnr)
	local context = config.options.ui.fold_context

	local levels = {}
	for i = 1, total do
		levels[i] = 1
	end

	for _, hunk in ipairs(file.hunks) do
		local first, last = hunk_mod.new_range(hunk)
		if first == 0 then
			first, last = math.max(1, hunk.new_start), math.max(1, hunk.new_start)
		end

		for lnum = math.max(1, first - context), math.min(total, last + context) do
			levels[lnum] = 0
		end
	end

	fold_levels[bufnr] = levels
end

---Used as `foldexpr` in the review window.
---@return integer
function M.foldexpr()
	local levels = fold_levels[vim.api.nvim_get_current_buf()]
	if not levels then
		return 0
	end
	return levels[vim.v.lnum] or 0
end

---@param bufnr integer
function M.clear(bufnr)
	if vim.api.nvim_buf_is_valid(bufnr) then
		vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
	end
	fold_levels[bufnr] = nil
end

---Decorate `bufnr` with `file`'s hunks.
---@param bufnr integer
---@param file draven.File
---@param session draven.Session
---@param opts? { width?: integer, deleted_file?: boolean }
function M.render(bufnr, file, session, opts)
	opts = opts or {}

	if not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)

	local width = opts.width or vim.o.columns

	if opts.deleted_file then
		-- The whole buffer is the pre-image; there is nothing to interleave.
		local total = line_count(bufnr)
		highlight_range(bufnr, 1, total, "DravenDelete")

		local status = #file.hunks > 0 and session:hunk_state(file.hunks[1]) or "unread"
		local glyph, glyph_hl = status_sign(status)

		sign(bufnr, 1, glyph, glyph_hl)
		for lnum = 2, total do
			sign(bufnr, lnum, config.options.ui.signs.hunk, "DravenSignBar")
		end

		fold_levels[bufnr] = nil
		return
	end

	for _, hunk in ipairs(file.hunks) do
		render_hunk(bufnr, hunk, session:hunk_state(hunk), width)
	end

	render_findings(bufnr, file, session, width)

	-- Always computed, even when folding is off: the window's `foldenable` is
	-- what decides, so it can be toggled without a re-render.
	compute_folds(bufnr, file)
end

---Repaint only the signs, for when a mark changed but nothing else did.
---@param bufnr integer
---@param file draven.File
---@param session draven.Session
---@param opts? { width?: integer, deleted_file?: boolean }
function M.refresh_signs(bufnr, file, session, opts)
	M.render(bufnr, file, session, opts)
end

return M
