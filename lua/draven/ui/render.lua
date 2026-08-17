---Diff decoration.
---
---Nothing here writes to a buffer. Added lines get a ranged highlight, deleted
---lines become virtual lines, and review state lives in the sign column — so
---the buffer under all of it stays the real file, with LSP attached, treesitter
---live and every one of your mappings working.
local config = require("draven.config")
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

	local virt_lines = {}
	for i, text in ipairs(texts) do
		local pad = math.max(0, width - indent - vim.fn.strdisplaywidth(text))
		virt_lines[i] = {
			{ marker, "DravenMarkerDelete" },
			{ text .. string.rep(" ", pad), "DravenDelete" },
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

	local glyph, glyph_hl = status_sign(status)
	sign(bufnr, first, glyph, glyph_hl)

	for lnum = first + 1, last do
		sign(bufnr, lnum, signs.hunk, "DravenSignBar")
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

---Findings sit above the line they point at, drawn as a box.
---
---End-of-line text is invisible on a long line, which is exactly the kind of
---line worth commenting on. A box above it is always readable, shows a
---multi-line comment in full, and reads as a note *about* the code rather
---than part of it. Collapse one to a single line with the toggle key; a
---resolved finding collapses on its own.
---@param bufnr integer
---@param file draven.File
---@param session draven.Session
---@param width integer
local function render_findings(bufnr, file, session, width)
	local mode = config.options.ui.finding_display
	if mode == false or mode == "none" then
		return
	end

	local finding_mod = require("draven.finding")
	local total = line_count(bufnr)
	local dw = vim.fn.strdisplaywidth

	for _, item in ipairs(session:findings({ path = file.path })) do
		if item.lnum and item.lnum >= 1 and item.lnum <= total then
			local hl = finding_highlight(item)
			local border_hl = item.resolved and "DravenFindingResolved" or hl .. "Border"
			local label = ("%s %s"):format(item.resolved and "✓" or "▎", item.severity)
			local body = vim.split(vim.trim(item.body or ""), "\n", { plain = true })

			local virt_lines

			if mode == "eol" then
				pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, item.lnum - 1, 0, {
					virt_text = { { ("  %s · %s"):format(label, finding_mod.headline(item)), hl } },
					virt_text_pos = "eol",
					priority = 130,
				})
				goto continue
			elseif item.collapsed or item.resolved then
				local summary = ("  ▸ %s · %s"):format(label, finding_mod.headline(item))
				virt_lines = { { { summary, border_hl } } }
			else
				-- Fit the box to its content, but never past the window.
				local inner = dw(label) + 6
				for _, line in ipairs(body) do
					inner = math.max(inner, dw(line) + 3)
				end
				inner = math.min(inner, math.max(24, width - 6))

				local fill = math.max(1, inner - 3 - dw(label))
				virt_lines = {
					{ { "  ╭─ " .. label .. " " .. string.rep("─", fill) .. "╮", border_hl } },
				}

				for _, line in ipairs(body) do
					-- Long lines are cut rather than wrapped: the full text is
					-- always one <leader>rc away.
					if dw(line) > inner - 3 then
						line = vim.fn.strcharpart(line, 0, inner - 4) .. "…"
					end
					virt_lines[#virt_lines + 1] = {
						{ "  │ ", border_hl },
						{ line .. string.rep(" ", math.max(0, inner - 1 - dw(line))), hl },
						{ "│", border_hl },
					}
				end

				virt_lines[#virt_lines + 1] =
					{ { "  ╰" .. string.rep("─", inner) .. "╯", border_hl } }
			end

			pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, item.lnum - 1, 0, {
				virt_lines = virt_lines,
				virt_lines_above = true,
				priority = 130,
			})

			::continue::
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
