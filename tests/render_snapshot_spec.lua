local changeset_mod = require("draven.core.changeset")
local config = require("draven.config")
local helpers = require("helpers")
local render = require("draven.ui.render")
local session_mod = require("draven.session")

local function screen_line(row, width)
	local cells = {}
	for col = 1, width do
		cells[#cells + 1] = vim.fn.screenstring(row, col)
	end
	return (table.concat(cells):gsub("%s+$", ""))
end

---Capture the rows Neovim actually composes, not just their extmarks. The
---first four cells are the review's two fixed sign slots, so the snapshot
---starts at the diff marker/comment rail shared by source and virtual lines.
local function screen_snapshot(bufnr, height, width)
	local win = vim.api.nvim_get_current_win()
	local saved_buf = vim.api.nvim_get_current_buf()
	local saved_view = vim.fn.winsaveview()
	local saved_columns, saved_lines = vim.o.columns, vim.o.lines
	local saved = {
		signcolumn = vim.wo[win].signcolumn,
		number = vim.wo[win].number,
		relativenumber = vim.wo[win].relativenumber,
		foldcolumn = vim.wo[win].foldcolumn,
		foldenable = vim.wo[win].foldenable,
		wrap = vim.wo[win].wrap,
		winbar = vim.wo[win].winbar,
	}

	vim.o.columns = math.max(80, width + 4)
	vim.o.lines = math.max(24, height + 2)
	vim.api.nvim_win_set_buf(win, bufnr)
	vim.wo[win].signcolumn = "yes:2"
	vim.wo[win].number = false
	vim.wo[win].relativenumber = false
	vim.wo[win].foldcolumn = "0"
	vim.wo[win].foldenable = false
	vim.wo[win].wrap = false
	vim.wo[win].winbar = ""
	vim.api.nvim_win_set_cursor(win, { 1, 0 })
	vim.fn.winrestview({ topline = 1, lnum = 1, col = 0 })
	vim.cmd("redraw!")

	local rows = {}
	for row = 1, height do
		local line = screen_line(row, width + 4)
		rows[row] = vim.fn.strcharpart(line, math.min(4, vim.fn.strchars(line)))
	end

	vim.api.nvim_win_set_buf(win, saved_buf)
	vim.wo[win].signcolumn = saved.signcolumn
	vim.wo[win].number = saved.number
	vim.wo[win].relativenumber = saved.relativenumber
	vim.wo[win].foldcolumn = saved.foldcolumn
	vim.wo[win].foldenable = saved.foldenable
	vim.wo[win].wrap = saved.wrap
	vim.wo[win].winbar = saved.winbar
	vim.fn.winrestview(saved_view)
	vim.o.columns, vim.o.lines = saved_columns, saved_lines
	return rows
end

local function chunk_snapshot(chunks)
	local out = {}
	for _, chunk in ipairs(chunks or {}) do
		out[#out + 1] = { text = chunk[1], hl = chunk[2] }
	end
	return out
end

local function decoration_snapshot(bufnr)
	local out = { inline = {}, virtual = {}, highlights = {} }
	for _, mark in
		ipairs(vim.api.nvim_buf_get_extmarks(bufnr, render.ns, 0, -1, { details = true }))
	do
		local row, details = mark[2] + 1, mark[4]
		if details.virt_text_pos == "inline" then
			out.inline[row] = out.inline[row] or {}
			out.inline[row][#out.inline[row] + 1] = chunk_snapshot(details.virt_text)
		elseif details.virt_lines then
			local lines = {}
			for _, chunks in ipairs(details.virt_lines) do
				lines[#lines + 1] = chunk_snapshot(chunks)
			end
			out.virtual[#out.virtual + 1] = {
				anchor = row,
				above = details.virt_lines_above == true,
				lines = lines,
			}
		elseif details.hl_group then
			out.highlights[#out.highlights + 1] = {
				first = row,
				last = (details.end_row or mark[2]) + 1,
				hl = details.hl_group,
			}
		end
	end
	return out
end

local function assert_range_markers(snapshot, first, glyphs, highlight)
	for offset, glyph in ipairs(glyphs) do
		local lnum = first + offset - 1
		local marks = snapshot.inline[lnum]
		assert.equals(1, #(marks or {}), "one fixed-width marker on line " .. lnum)
		assert.same({ { text = glyph .. " ", hl = highlight } }, marks[1])
		assert.equals(2, vim.fn.strdisplaywidth(marks[1][1].text))
	end
end

describe("rendered diff snapshots", function()
	local repo, session, scenario_buf

	before_each(function()
		config.setup({ ui = { fold_unchanged = false } })
		repo = helpers.repo()
	end)

	after_each(function()
		if scenario_buf and vim.api.nvim_buf_is_valid(scenario_buf) then
			render.clear(scenario_buf)
			vim.api.nvim_buf_delete(scenario_buf, { force = true })
		end
		repo:destroy()
		config.setup({})
	end)

	local function open_scenario(before, after)
		repo:write("scenario.lua", before)
		repo:commit("base")
		repo:write("scenario.lua", after)
		session = session_mod.new(helpers.build(repo))
		local file = changeset_mod.file(session.changeset, "scenario.lua")
		local bufnr = vim.fn.bufadd(repo.dir .. "/scenario.lua")
		vim.fn.bufload(bufnr)
		scenario_buf = bufnr
		return bufnr, file
	end

	local function add_range(file, first, last, body)
		local hunk = session:hunk_at(file, first)
		assert.is_not_nil(hunk, "the first selected line belongs to a hunk")
		assert.equals(hunk, session:hunk_at(file, last))
		local item = session:add_finding(hunk, first, {
			body = body,
			severity = "blocking",
			span = last - first + 1,
		})
		assert.is_not_nil(item)
		return item
	end

	it("captures an exact tab-indented addition with one stable marker column", function()
		local bufnr, file = open_scenario(
			{ "local keep = true", "", "return keep" },
			{
				"local keep = true",
				"",
				'\tlocal suffix = width > 1 and "…" or ""',
				"\tlocal limit = width - vim.fn.strdisplaywidth(suffix)",
				"\tlocal chars, used, take = vim.fn.strchars(text), 0, 0",
				"\tfor index = 1, chars do",
				"\t\tlocal char = vim.fn.strcharpart(text, index - 1, 1)",
				"\t\tlocal char_width = vim.fn.strdisplaywidth(char)",
				"",
				"return keep",
			}
		)
		add_range(file, 3, 8, "added block")

		render.render(bufnr, file, session, { width = 96 })
		local decorations = decoration_snapshot(bufnr)
		assert_range_markers(
			decorations,
			3,
			{ "╭", "│", "│", "│", "│", "│" },
			"DravenFindingBlocking"
		)

		local rows = screen_snapshot(bufnr, 11, 96)
		assert.equals('╭       local suffix = width > 1 and "…" or ""', rows[3])
		assert.equals("│       local limit = width - vim.fn.strdisplaywidth(suffix)", rows[4])
		assert.equals("│       for index = 1, chars do", rows[6])
		assert.equals(
			"│               local char_width = vim.fn.strdisplaywidth(char)",
			rows[8]
		)
		assert.is_truthy(rows[9]:find("^╰─ ● BLOCKING · L3–8  added block  ▸"))
	end)

	it("keeps the rail continuous across a replaced line and its deletion", function()
		local bufnr, file = open_scenario(
			{
				"local function value()",
				"\tlocal before = true",
				'\tlocal value = "old"',
				"\tlocal after = true",
				"end",
			},
			{
				"local function value()",
				"\tlocal before = true",
				'\tlocal value = "new"',
				"\tlocal after = true",
				"end",
			}
		)
		add_range(file, 2, 4, "replacement block")

		render.render(bufnr, file, session, { width = 96 })
		local decorations = decoration_snapshot(bufnr)
		assert_range_markers(
			decorations,
			2,
			{ "╭", "│", "│" },
			"DravenFindingBlocking"
		)

		local rows = screen_snapshot(bufnr, 8, 96)
		assert.equals("╭       local before = true", rows[2])
		assert.is_truthy(rows[3]:find('^│%-      local value = "old"'))
		assert.equals('│       local value = "new"', rows[4])
		assert.equals("│       local after = true", rows[5])
		assert.is_truthy(rows[6]:find("^╰─ ● BLOCKING · L2–4  replacement block  ▸"))

		local bridged
		for _, mark in ipairs(decorations.virtual) do
			if mark.above and mark.anchor == 3 then
				bridged = mark.lines[1]
			end
		end
		assert.same({
			{ text = "│", hl = "DravenFindingBlocking" },
			{ text = "-", hl = "DravenMarkerDelete" },
		}, { bridged[1], bridged[2] })
		assert.equals("DravenDelete", bridged[3].hl)
		assert.is_truthy(bridged[3].text:find('^\tlocal value = "old"'))
		assert.equals(94, vim.fn.strdisplaywidth(bridged[3].text))
	end)

	it("keeps the rail continuous when a pure deletion sits inside the range", function()
		local bufnr, file = open_scenario(
			{
				"local before = true",
				'local removed = "gone"',
				"local after = true",
				"return after",
			},
			{
				"local before = true",
				"local after = true",
				"return after",
			}
		)
		add_range(file, 1, 2, "deletion block")

		render.render(bufnr, file, session, { width = 80 })
		local rows = screen_snapshot(bufnr, 7, 80)
		assert.equals("╭ local before = true", rows[1])
		assert.is_truthy(rows[2]:find('^│%-local removed = "gone"'))
		assert.equals("│ local after = true", rows[3])
		assert.is_truthy(rows[4]:find("^╰─ ● BLOCKING · L1–2  deletion block  ▸"))
	end)

	it("styles a context-only block with the same fixed-width rail", function()
		local bufnr, file = open_scenario(
			{ "before", "context one", "context two", "old", "after" },
			{ "before", "context one", "context two", "new", "after" }
		)
		add_range(file, 1, 3, "context block")

		render.render(bufnr, file, session, { width = 80 })
		local decorations = decoration_snapshot(bufnr)
		assert_range_markers(
			decorations,
			1,
			{ "╭", "│", "│" },
			"DravenFindingBlocking"
		)
		local rows = screen_snapshot(bufnr, 8, 80)
		assert.same({ "╭ before", "│ context one", "│ context two" }, { rows[1], rows[2], rows[3] })
		assert.is_truthy(rows[4]:find("^╰─ ● BLOCKING · L1–3  context block  ▸"))
	end)

	it("keeps a single-line addition compact without adding a second marker", function()
		local bufnr, file = open_scenario(
			{ "local before = true", "return before" },
			{ "local before = true", "\tlocal added = true", "return before" }
		)
		add_range(file, 2, 2, "single line")

		render.render(bufnr, file, session, { width = 80 })
		local decorations = decoration_snapshot(bufnr)
		assert.same({ { text = "+ ", hl = "DravenMarkerAdd" } }, decorations.inline[2][1])
		assert.equals(1, #decorations.inline[2])

		local rows = screen_snapshot(bufnr, 5, 80)
		assert.equals("+       local added = true", rows[2])
		assert.is_truthy(rows[3]:find("^  ╰─ ● BLOCKING · L2  single line  ▸"))
	end)

	it("closes a block before a trailing deletion outside its post-image range", function()
		local bufnr, file = open_scenario(
			{ "local before = true", "local kept = true", 'local removed = "tail"' },
			{ "local before = true", "local kept = true" }
		)
		add_range(file, 1, 2, "before trailing deletion")

		render.render(bufnr, file, session, { width = 80 })
		local rows = screen_snapshot(bufnr, 6, 80)
		assert.equals("╭ local before = true", rows[1])
		assert.equals("│ local kept = true", rows[2])
		assert.is_truthy(rows[3]:find("^╰─ ● BLOCKING · L1–2  before trailing deletion  ▸"))
		assert.is_truthy(rows[4]:find('^%- local removed = "tail"'))
	end)

	it("keeps an above-mode card between a leading deletion and its range", function()
		config.setup({ ui = { finding_display = "above", fold_unchanged = false } })
		local bufnr, file = open_scenario(
			{ "local lead = true", 'local value = "old"', "return value" },
			{ "local lead = true", 'local value = "new"', "return value" }
		)
		add_range(file, 2, 3, "above replacement")

		render.render(bufnr, file, session, { width = 80 })
		local rows = screen_snapshot(bufnr, 7, 80)
		assert.equals("  local lead = true", rows[1])
		assert.is_truthy(rows[2]:find('^%- local value = "old"'))
		assert.is_truthy(rows[3]:find("^╭─ ● BLOCKING · L2–3  above replacement  ▸"))
		assert.equals('│ local value = "new"', rows[4])
		assert.equals("╰ return value", rows[5])
	end)
end)
