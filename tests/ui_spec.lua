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
			for _, m in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, render.ns, 0, -1, { details = true })) do
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
		assert.is_truthy(lines()[3]:match(("0/%d hunks · 0%%%%"):format(total)))

		session:mark_all(true)
		panel:render(session, nil)
		assert.is_truthy(lines()[3]:match("100%%"))
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

		local before = vim.api.nvim_buf_get_lines(panel_buf, 0, -1, false)[3]
		assert.is_truthy(before:match("^ 0/"))

		vim.api.nvim_set_current_win(view_win)
		ui.mark_hunk(true)
		vim.wait(300)

		local after = vim.api.nvim_buf_get_lines(panel_buf, 0, -1, false)[3]
		assert.is_truthy(after:match("^ 1/"), "expected one hunk marked, got: " .. after)
	end)

	it("marks a whole file from the panel", function()
		open_review()
		local panel_buf = windows()

		ui.focus_panel()
		local panel = require("draven.ui.panel")
		local _ = panel

		ui.mark_all(true)
		vim.wait(300)

		local progress = vim.api.nvim_buf_get_lines(panel_buf, 0, -1, false)[3]
		assert.is_truthy(progress:match("100%%"), "got: " .. progress)
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
		local progress = vim.api.nvim_buf_get_lines(panel_buf, 0, -1, false)[3]

		assert.is_truthy(progress:match("^ 1/"), "the mark should have survived, got: " .. progress)
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
			return notified ~= nil
		end, 10)
		vim.notify = original

		assert.is_false(ui.is_open())
		assert.is_truthy(tostring(notified):match("no changes"))
	end)
end)
