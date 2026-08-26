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
---@param rail? { hl: string }
local function virtual_deletions(bufnr, lnum, above, texts, width, rail)
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
	local marker_chunks = rail and {
		{ "│", rail.hl },
		{ signs.delete, "DravenMarkerDelete" },
	} or {
		{ marker, "DravenMarkerDelete" },
	}

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
		virt_lines[i] = vim.deepcopy(marker_chunks)
		virt_lines[i][#virt_lines[i] + 1] = {
			text .. string.rep(" ", pad),
			"DravenDelete",
		}
	end

	if hidden > 0 then
		local summary = ("… %d more deleted line%s · <leader>rd opens full hunk"):format(
			hidden,
			hidden == 1 and "" or "s"
		)
		local row = vim.deepcopy(marker_chunks)
		row[#row + 1] = {
			truncate_display(summary, math.max(1, width - indent)),
			"DravenDelete",
		}
		virt_lines[#virt_lines + 1] = row
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
---@param finding_rails table<integer, { text: string, hl: string, id: string }>
local function render_hunk(bufnr, hunk, status, width, finding_rails)
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
				local rail = finding_rails[lnum]
				inline_marker(
					bufnr,
					lnum,
					rail and rail.text or add_marker,
					rail and rail.hl or "DravenMarkerAdd"
				)
			end
			add_first, add_last = nil, nil
		end
	end

	local function flush_deletes(anchor, above)
		if #deletes > 0 then
			local rail
			if above then
				local before, after = finding_rails[anchor - 1], finding_rails[anchor]
				if before and after and before.id == after.id then
					rail = after
				end
			end
			virtual_deletions(bufnr, anchor, above, deletes, width, rail)
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
			local rail = finding_rails[line.new_lnum]
			inline_marker(
				bufnr,
				line.new_lnum,
				rail and rail.text or blank,
				rail and rail.hl or "DravenMarkerContext"
			)
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

---@param file draven.File
---@param session draven.Session
---@param total integer
---@param mode "below"|"above"|"eol"|false
---@return table<integer, { text: string, hl: string, id: string }>
local function finding_range_rails(file, session, total, mode)
	local rails = {}
	if mode == false or mode == "none" then
		return rails
	end

	for _, item in ipairs(session:findings({ path = file.path })) do
		local first = finding_mod.display_lnum(item, total)
		local span = item.lnum and math.max(1, item.span or 1) or 1
		if first and span > 1 and item.state ~= "orphaned" then
			local last = math.min(total, first + span - 1)
			local hl = finding_highlight(item)
			for lnum = first, last do
				if not rails[lnum] then
					local glyph = "│"
					if mode == "above" and lnum == last then
						glyph = "╰"
					elseif mode ~= "above" and lnum == first then
						glyph = "╭"
					end
					rails[lnum] = { text = glyph .. " ", hl = hl, id = item.id }
				end
			end
		end
	end

	return rails
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
	local severity = (item.severity or "blocking"):upper()
	local span = item.lnum and math.max(1, item.span or 1) or 1
	local scope = ""
	if item.lnum then
		scope = span > 1 and (" · L%d–%d"):format(item.lnum, item.lnum + span - 1)
			or (" · L%d"):format(item.lnum)
	end
	if item.state == "orphaned" then
		return "⚠ ORPHANED · " .. severity
	end
	if item.resolved then
		return "✓ RESOLVED · " .. severity .. scope
	end

	local icon = ({ blocking = "●", question = "?", nit = "◇" })[item.severity] or "●"
	return icon .. " " .. severity .. scope
end

---@param item draven.Finding
---@param width integer
---@param mode "below"|"above"|"eol"
---@return table[]
local function finding_rows(item, width, mode)
	local hl = finding_highlight(item)
	local badge = finding_badge(item)
	local rows = {}
	local max_width = config.options.ui.finding and config.options.ui.finding.max_width or 96
	local available_width = math.max(1, math.min(width, max_width))
	local headline = finding_mod.headline(item)
	local block = item.lnum ~= nil and math.max(1, item.span or 1) > 1
	-- Range cards continue directly from the rail in the second sign slot.
	-- Single-line findings retain a small inset to separate them from the diff.
	local indent = block and "" or "  "

	if item.collapsed then
		local corner = block and mode == "above" and "╭" or "╰"
		local prefix = indent .. corner .. "─ " .. badge .. "  "
		local suffix = "  ▸"
		local fixed = vim.fn.strdisplaywidth(prefix) + vim.fn.strdisplaywidth(suffix)
		local row_width = math.min(
			available_width,
			math.max(math.min(36, available_width), fixed + vim.fn.strdisplaywidth(headline))
		)

		if row_width <= fixed then
			rows[1] = { { truncate_display(prefix .. suffix, row_width), hl } }
			return rows
		end

		rows[1] = {
			{ prefix, hl },
			{ truncate_display(headline, row_width - fixed), "DravenFindingText" },
			{ suffix, hl },
		}
		return rows
	end

	local body = vim.split(vim.trim(item.body or ""), "\n", { plain = true })
	local widest = vim.fn.strdisplaywidth(badge) + 13
	for _, line in ipairs(body) do
		widest = math.max(widest, vim.fn.strdisplaywidth(line) + 8)
	end

	local card_width = math.min(available_width, math.max(math.min(44, available_width), widest))
	if card_width < 12 then
		return { { { truncate_display(badge .. " " .. headline, card_width), hl } } }
	end

	local header_corner = block and mode ~= "above" and "├" or "╭"
	local header_start = indent .. header_corner .. "─ "
	local header_end = " ▾ ╮"
	local rule_width = card_width
		- vim.fn.strdisplaywidth(header_start)
		- vim.fn.strdisplaywidth(badge)
		- vim.fn.strdisplaywidth(header_end)
	if rule_width > 0 then
		local rule = " " .. string.rep("─", rule_width - 1)
		rows[1] = { { header_start .. badge .. rule .. header_end, hl } }
	else
		rows[1] = { { truncate_display(header_start .. badge .. " ▾", card_width), hl } }
	end

	local body_left, body_right = indent .. "│  ", "  │"
	local body_width = math.max(
		1,
		card_width - vim.fn.strdisplaywidth(body_left) - vim.fn.strdisplaywidth(body_right)
	)
	for _, line in ipairs(body) do
		for _, wrapped in ipairs(wrap_display(line, body_width)) do
			local pad = math.max(0, body_width - vim.fn.strdisplaywidth(wrapped))
			rows[#rows + 1] = {
				{ body_left, hl },
				{ wrapped, "DravenFindingText" },
				{ string.rep(" ", pad), "DravenFindingSurface" },
				{ body_right, hl },
			}
		end
	end

	local bottom_corner = block and mode == "above" and "├" or "╰"
	local bottom_width = math.max(0, card_width - vim.fn.strdisplaywidth(indent) - 2)
	rows[#rows + 1] = { { indent .. bottom_corner .. string.rep("─", bottom_width) .. "╯", hl } }

	return rows
end

---Findings mark their source range in the review gutter and render as
---annotations beside it. A collapsed finding is one compact summary;
---expanding it produces a bounded review card with a separate header and
---wrapped body.
---Findings sharing an annotation anchor are combined into one virtual block so
---their text never overlaps.
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
		local first = finding_mod.display_lnum(item, total)
		if first then
			local span = item.lnum and math.max(1, item.span or 1) or 1
			local last = math.min(total, first + span - 1)
			local anchor = mode == "above" and first or last
			by_line[anchor] = by_line[anchor] or {}
			by_line[anchor][#by_line[anchor] + 1] = {
				item = item,
				first = first,
				last = last,
			}
		end
	end

	for lnum, entries in pairs(by_line) do
		local rows, eol = {}, {}
		for _, entry in ipairs(entries) do
			local item = entry.item
			if mode == "eol" and item.collapsed then
				if #eol > 0 then
					eol[#eol + 1] = { "   ", "Comment" }
				end
				local item_hl = finding_highlight(item)
				eol[#eol + 1] = { "  ╰─ " .. finding_badge(item) .. "  ", item_hl }
				eol[#eol + 1] = { finding_mod.headline(item), "DravenFindingText" }
				eol[#eol + 1] = { "  ▸", item_hl }
			else
				vim.list_extend(rows, finding_rows(item, width, mode))
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

	local finding_rails = finding_range_rails(
		file,
		session,
		line_count(bufnr),
		config.options.ui.finding_display
	)
	-- Virtual lines sharing an anchor follow creation order. Below-mode cards
	-- must close before a trailing deletion, while above-mode cards must sit
	-- after a leading deletion and immediately beside their first source line.
	local findings_above = config.options.ui.finding_display == "above"
	if not findings_above then
		render_findings(bufnr, file, session, width)
	end
	for _, hunk in ipairs(file.hunks) do
		render_hunk(bufnr, hunk, session:hunk_state(hunk), width, finding_rails)
	end
	if findings_above then
		render_findings(bufnr, file, session, width)
	end

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
