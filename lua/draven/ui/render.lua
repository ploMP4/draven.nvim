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

---Render deleted lines as virtual lines, padded so their background runs the
---full width instead of stopping at the text.
---@param bufnr integer
---@param lnum integer # anchor line, 1-based
---@param above boolean
---@param texts string[]
---@param width integer
local function virtual_deletions(bufnr, lnum, above, texts, width)
	if #texts == 0 then
		return
	end

	local total = line_count(bufnr)
	lnum = math.max(1, math.min(lnum, total))

	local virt_lines = {}
	for i, text in ipairs(texts) do
		local pad = math.max(0, width - vim.fn.strdisplaywidth(text))
		virt_lines[i] = { { text .. string.rep(" ", pad), "DravenDelete" } }
	end

	pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, lnum - 1, 0, {
		virt_lines = virt_lines,
		virt_lines_above = above,
		priority = 100,
	})
end

---@param bufnr integer
---@param lnum integer
---@param text string
---@param group string
local function sign(bufnr, lnum, text, group)
	if lnum < 1 or lnum > line_count(bufnr) then
		return
	end

	pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, lnum - 1, 0, {
		sign_text = text,
		sign_hl_group = group,
		priority = 120,
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

	local function flush_adds()
		if add_first then
			highlight_range(bufnr, add_first, add_last, "DravenAdd")
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

---Findings sit at the end of the line they point at, so the code stays put.
---@param bufnr integer
---@param file draven.File
---@param session draven.Session
local function render_findings(bufnr, file, session)
	if not config.options.ui.finding_virt_text then
		return
	end

	local finding_mod = require("draven.finding")
	local total = line_count(bufnr)

	for _, item in ipairs(session:findings({ path = file.path })) do
		if item.lnum and item.lnum >= 1 and item.lnum <= total then
			local label = ("  %s %s: %s"):format(
				item.resolved and "✓" or "▎",
				item.severity,
				finding_mod.headline(item)
			)

			pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, item.lnum - 1, 0, {
				virt_text = { { label, finding_highlight(item) } },
				virt_text_pos = "eol",
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

	render_findings(bufnr, file, session)

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
