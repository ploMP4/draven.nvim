local config = require("draven.config")
local helpers = require("helpers")
local render = require("draven.ui.render")
local session_mod = require("draven.session")
local ui = require("draven.ui")

---A file long enough that folding has something to hide.
local function filler(n, marker)
	local lines = {}
	for i = 1, n do
		lines[i] = ("\t// filler line %d%s"):format(i, marker and i == 3 and " " .. marker or "")
	end
	return lines
end

---@param repo table
local function seed(repo)
	local base = { "package auth", "" }
	vim.list_extend(base, filler(40))
	vim.list_extend(base, { "func Validate() error {", "\treturn nil", "}" })
	repo:write("auth/token.go", base)
	repo:write("db/query.go", { "package db", "", "func Get() {}" })
	repo:commit("init")

	local edited = { "package auth", "" }
	vim.list_extend(edited, filler(40, "CHANGED"))
	vim.list_extend(edited, { "func Validate() error {", "\tcheck()", "\treturn nil", "}" })
	repo:write("auth/token.go", edited)
	repo:write("db/query.go", { "package db", "", "func Get() { check() }" })
	repo:write("db/new.go", { "package db", "", "func Brand() {}" })
end

--- Rendering -----------------------------------------------------------------

describe("render", function()
	local repo, session

	before_each(function()
		config.setup({})
		repo = helpers.repo()
		seed(repo)
		session = session_mod.new(helpers.build(repo))
	end)

	after_each(function()
		repo:destroy()
		config.setup({})
	end)

	---@return integer bufnr, draven.File
	local function open(path)
		local file = require("draven.core.changeset").file(session.changeset, path)
		local bufnr = vim.fn.bufadd(repo.dir .. "/" .. path)
		vim.fn.bufload(bufnr)
		return bufnr, file
	end

	local function add_finding(file, body, severity)
		for _, hunk in ipairs(file.hunks) do
			for _, line in ipairs(hunk.lines) do
				if line.new_lnum and line.text:find("CHANGED", 1, true) then
					return session:add_finding(hunk, line.new_lnum, {
						body = body,
						severity = severity or "blocking",
					})
				end
			end
		end
		error("could not find the changed fixture line")
	end

	local function virtual_text(lines)
		local out = {}
		for _, row in ipairs(lines or {}) do
			local parts = {}
			for _, chunk in ipairs(row) do
				parts[#parts + 1] = chunk[1]
			end
			out[#out + 1] = table.concat(parts)
		end
		return table.concat(out, "\n")
	end

	local function finding_marks(bufnr, needle)
		local out = {}
		for _, mark in
			ipairs(vim.api.nvim_buf_get_extmarks(bufnr, render.ns, 0, -1, { details = true }))
		do
			local details = mark[4]
			if details.virt_lines and virtual_text(details.virt_lines):find(needle, 1, true) then
				out[#out + 1] = details
			end
		end
		return out
	end

	it("decorates without touching buffer text", function()
		local bufnr, file = open("auth/token.go")
		local before = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

		render.render(bufnr, file, session, { width = 80 })

		assert.same(before, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
		assert.is_false(vim.bo[bufnr].modified)
	end)

	it("leaves the buffer a real, editable file buffer", function()
		local bufnr, file = open("auth/token.go")
		render.render(bufnr, file, session, { width = 80 })

		assert.equals("", vim.bo[bufnr].buftype)
		assert.is_true(vim.bo[bufnr].modifiable)
		assert.equals("go", vim.bo[bufnr].filetype)
	end)

	it("marks added lines and renders deletions as virtual lines", function()
		local bufnr, file = open("auth/token.go")
		render.render(bufnr, file, session, { width = 80 })

		local marks = vim.api.nvim_buf_get_extmarks(bufnr, render.ns, 0, -1, { details = true })

		local adds, virt, signs = 0, 0, 0
		for _, m in ipairs(marks) do
			local d = m[4]
			if d.hl_group == "DravenAdd" then
				adds = adds + 1
			elseif d.virt_lines then
				virt = virt + 1
			elseif d.sign_text then
				signs = signs + 1
			end
		end

		assert.is_true(adds > 0, "expected added-line highlights")
		assert.is_true(virt > 0, "expected virtual lines for deletions")
		assert.is_true(signs > 0, "expected review-state signs")
	end)

	it("shows the reviewed glyph once a hunk is marked", function()
		local bufnr, file = open("db/query.go")

		local function sign_texts()
			local out = {}
			for _, m in
				ipairs(vim.api.nvim_buf_get_extmarks(bufnr, render.ns, 0, -1, { details = true }))
			do
				if m[4].sign_text then
					out[#out + 1] = vim.trim(m[4].sign_text)
				end
			end
			return out
		end

		render.render(bufnr, file, session, { width = 80 })
		assert.is_truthy(vim.tbl_contains(sign_texts(), config.options.ui.signs.unread))

		session:mark_file(file, true)
		render.render(bufnr, file, session, { width = 80 })
		assert.is_truthy(vim.tbl_contains(sign_texts(), config.options.ui.signs.reviewed))
	end)

	it("folds code away from hunks and keeps context around them", function()
		local bufnr, file = open("auth/token.go")
		render.render(bufnr, file, session, { width = 80 })

		local hunk_mod = require("draven.core.hunk")
		local first = select(1, hunk_mod.new_range(file.hunks[1]))

		local saved = vim.api.nvim_get_current_buf()
		vim.api.nvim_set_current_buf(bufnr)

		-- Lines at the hunk stay visible; something far away does not.
		vim.v.lnum = first
		assert.equals(0, render.foldexpr())

		local folded_somewhere = false
		for lnum = 1, vim.api.nvim_buf_line_count(bufnr) do
			vim.v.lnum = lnum
			if render.foldexpr() == 1 then
				folded_somewhere = true
				break
			end
		end
		assert.is_true(folded_somewhere, "a 45-line file with two hunks should fold something")

		vim.api.nvim_set_current_buf(saved)
	end)

	it("renders new findings as compact annotations below their source", function()
		local bufnr, file = open("auth/token.go")
		local item = add_finding(file, "Keep this visible", "question")

		assert.is_true(item.collapsed)
		render.render(bufnr, file, session, { width = 60 })

		local marks = finding_marks(bufnr, "Keep this visible")
		assert.equals(1, #marks)
		assert.equals(1, #marks[1].virt_lines)
		assert.is_truthy(virtual_text(marks[1].virt_lines):find("▸", 1, true))
		assert.not_equals(true, marks[1].virt_lines_above)
	end)

	it("expands findings into a distinct wrapped body without losing text", function()
		local bufnr, file = open("auth/token.go")
		local item = add_finding(
			file,
			"This explanation is deliberately longer than the view width.\nThe final words stay visible.",
			"blocking"
		)

		assert.is_false(session:toggle_collapsed(item.id))
		render.render(bufnr, file, session, { width = 32 })

		local marks = finding_marks(bufnr, "deliberately")
		assert.equals(1, #marks)
		assert.is_true(#marks[1].virt_lines > 3)

		local text = virtual_text(marks[1].virt_lines)
		assert.is_truthy(text:find("▾", 1, true))
		assert.is_truthy(text:find("final words", 1, true))
		for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
			assert.is_true(vim.fn.strdisplaywidth(line) <= 32, ("finding row is too wide: %q"):format(line))
		end
	end)

	it("groups findings on the same source line into one annotation", function()
		local bufnr, file = open("auth/token.go")
		add_finding(file, "First same-line finding", "blocking")
		add_finding(file, "Second same-line finding", "nit")

		render.render(bufnr, file, session, { width = 60 })

		local marks = finding_marks(bufnr, "same-line finding")
		assert.equals(1, #marks, "same-line findings must not create overlapping blocks")
		local text = virtual_text(marks[1].virt_lines)
		assert.is_truthy(text:find("First same-line finding", 1, true))
		assert.is_truthy(text:find("Second same-line finding", 1, true))
	end)

	it("allows resolved and eol findings to expand", function()
		config.setup({ ui = { finding_display = "eol" } })
		local bufnr, file = open("auth/token.go")
		local item = add_finding(file, "Resolved details can still expand", "nit")

		assert.is_true(session:toggle_resolved(item.id))
		assert.is_false(session:toggle_collapsed(item.id))
		render.render(bufnr, file, session, { width = 60 })

		local marks = finding_marks(bufnr, "Resolved details can still expand")
		assert.equals(1, #marks)
		assert.is_true(#marks[1].virt_lines >= 2)
		assert.is_truthy(virtual_text(marks[1].virt_lines):find("resolved", 1, true))
	end)

	it("renders an orphan at its last line without underlining unrelated code", function()
		local bufnr, file = open("auth/token.go")
		local item = add_finding(file, "The orphan remains visible", "question")
		item.lnum = nil
		item.state = "orphaned"

		render.render(bufnr, file, session, { width = 60 })

		local marks = finding_marks(bufnr, "The orphan remains visible")
		assert.equals(1, #marks)
		assert.is_truthy(virtual_text(marks[1].virt_lines):find("orphaned", 1, true))

		for _, mark in
			ipairs(vim.api.nvim_buf_get_extmarks(bufnr, render.ns, 0, -1, { details = true }))
		do
			assert.not_equals("DravenFindingQuestionLine", mark[4].hl_group)
		end
	end)

	it("caps long inline deletions and opens the full hunk in a scrollable buffer", function()
		config.setup({ ui = { max_inline_deletions = 4, delta = { max_height = 5 } } })
		local bufnr = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "after" })

		local diff_lines = {}
		for i = 1, 12 do
			diff_lines[#diff_lines + 1] = { kind = "delete", text = "removed " .. i, old_lnum = i }
		end
		diff_lines[#diff_lines + 1] = {
			kind = "context",
			text = "after",
			old_lnum = 13,
			new_lnum = 1,
		}

		local hunk = {
			id = "long-delete",
			index = 1,
			path = "large.txt",
			old_start = 1,
			old_count = 13,
			new_start = 1,
			new_count = 1,
			lines = diff_lines,
			added = 0,
			removed = 12,
		}
		local file = { path = "large.txt", hunks = { hunk } }
		local fake = {}
		function fake:hunk_state()
			return "unread"
		end
		function fake:findings()
			return {}
		end

		render.render(bufnr, file, fake, { width = 60 })
		local marks = finding_marks(bufnr, "more deleted lines")
		assert.equals(1, #marks)
		assert.equals(4, #marks[1].virt_lines)

		local delta = require("draven.ui.delta")
		delta.open(fake, hunk)
		local preview = vim.api.nvim_get_current_buf()
		assert.equals("draven-delta", vim.bo[preview].filetype)
		assert.is_true(vim.api.nvim_buf_line_count(preview) > 5)
		vim.cmd("normal! G")
		assert.equals(vim.api.nvim_buf_line_count(preview), vim.api.nvim_win_get_cursor(0)[1])
		delta.close()
		vim.api.nvim_buf_delete(bufnr, { force = true })
	end)

	it("clears every decoration it made", function()
		local bufnr, file = open("auth/token.go")
		render.render(bufnr, file, session, { width = 80 })
		render.clear(bufnr)

		assert.equals(0, #vim.api.nvim_buf_get_extmarks(bufnr, render.ns, 0, -1, {}))
	end)
end)

--- Panel ---------------------------------------------------------------------

describe("panel", function()
	local repo, session, panel

	before_each(function()
		config.setup({})
		repo = helpers.repo()
		seed(repo)
		session = session_mod.new(helpers.build(repo))
		panel = require("draven.ui.panel").new()
	end)

	after_each(function()
		repo:destroy()
		config.setup({})
	end)

	local function lines()
		return vim.api.nvim_buf_get_lines(panel.bufnr, 0, -1, false)
	end

	---The header line carrying the progress bar, whatever row it lands on.
	local function progress_line()
		for _, line in ipairs(lines()) do
			if line:find("▰") or line:find("▱") then
				return line
			end
		end
		return ""
	end

	it("groups files under their directory", function()
		panel:render(session, nil)
		local text = table.concat(lines(), "\n")

		assert.is_truthy(text:match("auth/"))
		assert.is_truthy(text:match("db/"))
		assert.is_truthy(text:match("token%.go"))
		assert.is_truthy(text:match("new%.go"))
	end)

	it("counts progress in hunks", function()
		panel:render(session, nil)
		local _, total = session:progress()

		assert.is_truthy(progress_line():match(("0/%d"):format(total)))
		assert.is_truthy(progress_line():match("0%%"))

		session:mark_all(true)
		panel:render(session, nil)
		assert.is_truthy(progress_line():match(("%d/%d"):format(total, total)))
		assert.is_truthy(progress_line():match("100%%"))
	end)

	it("maps lines back to files", function()
		panel:render(session, nil)

		local lnum = panel:line_of("db/query.go")
		assert.is_not_nil(lnum)

		local entry = panel:entry_at(lnum)
		assert.equals("file", entry.kind)
		assert.equals("db/query.go", entry.file.path)
	end)

	it("hides a collapsed directory's files", function()
		panel:render(session, nil)
		assert.is_not_nil(panel:line_of("db/query.go"))

		panel:toggle_dir("db/")
		panel:render(session, nil)

		assert.is_nil(panel:line_of("db/query.go"))
		assert.is_not_nil(panel:line_of("auth/token.go"), "other directories stay open")
	end)

	it("keeps orphaned findings addressable in a dedicated section", function()
		local entry = session.order[1]
		local lnum = entry.hunk.lines[#entry.hunk.lines].new_lnum
		local item = session:add_finding(entry.hunk, lnum, {
			body = "Orphan details",
			severity = "blocking",
		})
		item.lnum = nil
		item.state = "orphaned"

		panel:render(session, nil)
		local text = table.concat(lines(), "\n")
		assert.is_truthy(text:find("orphaned findings", 1, true))
		assert.is_truthy(text:find("Orphan details", 1, true))

		local found
		for row = 1, #lines() do
			local panel_entry = panel:entry_at(row)
			if panel_entry and panel_entry.kind == "finding" then
				found = panel_entry
				break
			end
		end
		assert.equals(item.id, found.finding.id)
	end)

	it("stays within its configured width", function()
		config.setup({ ui = { panel = { width = 30 } } })
		panel:render(session, nil)

		for _, line in ipairs(lines()) do
			assert.is_true(
				vim.fn.strdisplaywidth(line) <= 30,
				("line wider than the panel: %q"):format(line)
			)
		end
	end)

	it("is a scratch buffer with its own filetype", function()
		assert.equals("nofile", vim.bo[panel.bufnr].buftype)
		assert.equals("draven-panel", vim.bo[panel.bufnr].filetype)
		assert.is_false(vim.bo[panel.bufnr].modifiable)
	end)
end)

--- The review tab ------------------------------------------------------------

describe("review surface", function()
	local repo

	before_each(function()
		config.setup({})
		repo = helpers.repo()
		seed(repo)
		vim.api.nvim_set_current_dir(repo.dir)
	end)

	after_each(function()
		if ui.is_open() then
			ui.close()
		end
		repo:destroy()
		config.setup({})
	end)

	local function open_review()
		ui.open({ cwd = repo.dir })
		helpers.wait_for(function()
			return ui.is_open()
		end, "the review to open")
		-- The first file is shown asynchronously.
		helpers.wait_for(function()
			local wins = vim.api.nvim_tabpage_list_wins(vim.api.nvim_get_current_tabpage())
			for _, w in ipairs(wins) do
				if vim.bo[vim.api.nvim_win_get_buf(w)].filetype ~= "draven-panel" then
					return vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w)) ~= ""
				end
			end
			return false
		end, "the first file to load")
	end

	---@return integer panel_buf, integer view_buf, integer view_win
	local function windows()
		local panel_buf, view_buf, view_win
		for _, w in ipairs(vim.api.nvim_tabpage_list_wins(vim.api.nvim_get_current_tabpage())) do
			local b = vim.api.nvim_win_get_buf(w)
			if vim.bo[b].filetype == "draven-panel" then
				panel_buf = b
			else
				view_buf, view_win = b, w
			end
		end
		return panel_buf, view_buf, view_win
	end

	it("opens a tab with a panel and a diff window", function()
		open_review()

		local panel_buf, view_buf = windows()
		assert.is_not_nil(panel_buf)
		assert.is_not_nil(view_buf)
		assert.equals(2, #vim.api.nvim_tabpage_list_wins(vim.api.nvim_get_current_tabpage()))
	end)

	it("shows the real file, not a copy of it", function()
		open_review()
		local _, view_buf = windows()

		assert.equals("", vim.bo[view_buf].buftype)
		assert.is_truthy(vim.api.nvim_buf_get_name(view_buf):match("%.go$"))
	end)

	it("marking a hunk updates the panel and moves on", function()
		open_review()
		local panel_buf, _, view_win = windows()

		local function progress()
			for _, line in ipairs(vim.api.nvim_buf_get_lines(panel_buf, 0, -1, false)) do
				if line:find("▰") or line:find("▱") then
					return line
				end
			end
			return ""
		end

		assert.is_truthy(progress():match("0/%d+"))

		vim.api.nvim_set_current_win(view_win)
		ui.mark_hunk(true)
		vim.wait(300)

		assert.is_truthy(progress():match("1/%d+"), "expected one hunk marked, got: " .. progress())
	end)

	it("marks a whole file from the panel", function()
		open_review()
		local panel_buf = windows()

		ui.focus_panel()
		local panel = require("draven.ui.panel")
		local _ = panel

		ui.mark_all(true)
		vim.wait(300)

		local text = table.concat(vim.api.nvim_buf_get_lines(panel_buf, 0, -1, false), "\n")
		assert.is_truthy(text:match("100%%"), "got: " .. text)
	end)

	it("closes cleanly and leaves no decorations behind", function()
		open_review()
		local _, view_buf = windows()

		ui.close()
		vim.wait(200)

		assert.is_false(ui.is_open())
		if vim.api.nvim_buf_is_valid(view_buf) then
			assert.equals(0, #vim.api.nvim_buf_get_extmarks(view_buf, render.ns, 0, -1, {}))
		end
	end)

	it("does not leave its keymaps on your file buffers", function()
		-- A literal key, so the assertion does not depend on what <leader> is.
		local lhs = "<F5>"
		config.setup({ keymaps = { mark_hunk = lhs } })

		open_review()
		local _, view_buf = windows()

		local function has_map()
			for _, m in ipairs(vim.api.nvim_buf_get_keymap(view_buf, "n")) do
				if m.lhs == lhs then
					return true
				end
			end
			return false
		end

		assert.is_true(has_map(), "the review should map its keys while open")

		ui.close()
		vim.wait(200)

		assert.is_false(has_map(), "the review must unmap them again on close")
	end)

	it("never maps <CR> into a real file buffer", function()
		open_review()
		local panel_buf, view_buf = windows()

		local function has_cr(bufnr)
			for _, m in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do
				if m.lhs == "<CR>" then
					return true
				end
			end
			return false
		end

		assert.is_true(has_cr(panel_buf), "<CR> belongs in the panel")
		assert.is_false(has_cr(view_buf), "<CR> must not be hijacked in your own file")
	end)

	it("restores progress when reopened", function()
		open_review()
		local _, _, view_win = windows()

		vim.api.nvim_set_current_win(view_win)
		ui.mark_hunk(true)
		vim.wait(300)

		ui.close()
		vim.wait(300)

		open_review()
		local panel_buf = windows()
		local text = table.concat(vim.api.nvim_buf_get_lines(panel_buf, 0, -1, false), "\n")

		assert.is_truthy(text:match("1/%d+"), "the mark should have survived: " .. text)
	end)

	it("opens an orphan-only review and lets the panel view and delete it", function()
		local session = session_mod.new(helpers.build(repo))
		local entry = session.order[1]
		local lnum
		for _, line in ipairs(entry.hunk.lines) do
			lnum = line.new_lnum or lnum
		end
		local item = session:add_finding(entry.hunk, lnum, {
			body = "Orphan-only details",
			severity = "blocking",
		})
		item.lnum = nil
		item.state = "orphaned"
		session:save()

		local base = { "package auth", "" }
		vim.list_extend(base, filler(40))
		vim.list_extend(base, { "func Validate() error {", "\treturn nil", "}" })
		repo:write("auth/token.go", base)
		repo:write("db/query.go", { "package db", "", "func Get() {}" })
		repo:remove("db/new.go")

		ui.open({ cwd = repo.dir })
		helpers.wait_for(function()
			return ui.is_open()
		end, "the orphan-only review to open")

		local panel_win, panel_buf
		for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
			local bufnr = vim.api.nvim_win_get_buf(win)
			if vim.bo[bufnr].filetype == "draven-panel" then
				panel_win, panel_buf = win, bufnr
				break
			end
		end

		local row
		for index, line in ipairs(vim.api.nvim_buf_get_lines(panel_buf, 0, -1, false)) do
			if line:find("Orphan%-only details") then
				row = index
				break
			end
		end
		assert.is_not_nil(row)

		vim.api.nvim_set_current_win(panel_win)
		vim.api.nvim_win_set_cursor(panel_win, { row, 0 })
		ui.open_entry()
		assert.equals("draven://finding", vim.api.nvim_buf_get_name(0))
		assert.equals("Orphan-only details", vim.api.nvim_get_current_line())
		require("draven.ui.comment").close()

		vim.api.nvim_set_current_win(panel_win)
		vim.api.nvim_win_set_cursor(panel_win, { row, 0 })
		ui.delete_finding()
		local text = table.concat(vim.api.nvim_buf_get_lines(panel_buf, 0, -1, false), "\n")
		assert.is_nil(text:find("Orphan%-only details"))
	end)

	it("reports that there is nothing to review on a clean tree", function()
		repo:commit("everything")

		local notified
		local original = vim.notify
		vim.notify = function(msg)
			notified = msg
		end

		ui.open({ cwd = repo.dir })
		vim.wait(3000, function()
			return tostring(notified):match("no changes") ~= nil
		end, 10)
		vim.notify = original

		assert.is_false(ui.is_open())
		assert.is_truthy(tostring(notified):match("no changes"))
	end)
end)
