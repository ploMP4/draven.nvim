local config = require("draven.config")
local helpers = require("helpers")
local session_mod = require("draven.session")
local state_store = require("draven.state")

---A repo with three files and a known hunk count.
---@param repo table
local function seed(repo)
	repo:write("a.txt", { "one", "two", "three" })
	repo:write("b.txt", { "alpha" })
	repo:commit("init")

	repo:write("a.txt", { "ONE", "two", "THREE" })
	repo:write("b.txt", { "ALPHA" })
	repo:write("c.txt", { "brand new" })
end

describe("session", function()
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

	it("orders every reviewable hunk", function()
		-- a.txt has two separate hunks (lines 1 and 3 are not adjacent at -U3
		-- they are, so a.txt yields one), b.txt one, c.txt one.
		assert.is_true(#session.order >= 3)

		for i, entry in ipairs(session.order) do
			assert.equals(i, entry.position)
			assert.is_not_nil(entry.file)
			assert.is_not_nil(entry.hunk)
		end
	end)

	it("starts with nothing reviewed", function()
		local reviewed, total = session:progress()
		assert.equals(0, reviewed)
		assert.equals(#session.order, total)
	end)

	it("marks and unmarks a hunk", function()
		local hunk = session.order[1].hunk

		assert.is_false(session:is_reviewed(hunk))
		session:mark(hunk, true)
		assert.is_true(session:is_reviewed(hunk))
		assert.equals("reviewed", session:hunk_state(hunk))

		session:mark(hunk, false)
		assert.is_false(session:is_reviewed(hunk))
		assert.equals("unread", session:hunk_state(hunk))
	end)

	it("reports file state as unread, partial or reviewed", function()
		local file = session.order[1].file

		assert.equals("unread", session:file_state(file))

		session:mark(file.hunks[1], true)
		if #file.hunks > 1 then
			assert.equals("partial", session:file_state(file))
		end

		session:mark_file(file, true)
		assert.equals("reviewed", session:file_state(file))

		local done, total = session:file_progress(file)
		assert.equals(total, done)
	end)

	it("counts ignored files as neither reviewed nor unread", function()
		repo:write("go.sum", { "generated" })
		session:update(helpers.build(repo))

		local lock
		for _, f in ipairs(session.changeset.files) do
			if f.path == "go.sum" then
				lock = f
			end
		end

		assert.is_not_nil(lock)
		assert.equals("ignored", session:file_state(lock))

		-- Ignored hunks never enter the order, so they cannot block progress.
		for _, entry in ipairs(session.order) do
			assert.are_not.equals("go.sum", entry.file.path)
		end
	end)

	it("walks to the next unread hunk and wraps around", function()
		local first = session:next_unread(nil, false)
		assert.equals(1, first.position)

		session:mark(first.hunk, true)

		local second = session:next_unread(1, false)
		assert.equals(2, second.position)

		-- From the last position, wrap back to the first unread one.
		local wrapped = session:next_unread(#session.order, false)
		assert.equals(2, wrapped.position)
	end)

	it("walks backwards", function()
		local entry = session:next_unread(1, true)
		assert.equals(#session.order, entry.position)
	end)

	it("returns nothing once everything is read", function()
		session:mark_all(true)

		assert.is_nil(session:next_unread(nil, false))

		local reviewed, total = session:progress()
		assert.equals(total, reviewed)
	end)

	it("finds the hunk covering a line", function()
		local entry = session.order[1]
		local hunk_mod = require("draven.core.hunk")
		local first = select(1, hunk_mod.new_range(entry.hunk))

		assert.equals(entry.hunk.id, session:hunk_at(entry.file, first).id)
	end)

	it("falls back to the nearest hunk when the cursor is in unchanged code", function()
		local entry = session.order[1]
		assert.is_not_nil(session:nearest_hunk(entry.file, 1, false))
	end)

	it("keeps marks when the changeset is rebuilt", function()
		local hunk = session.order[1].hunk
		local path = hunk.path
		session:mark(hunk, true)

		-- Touch a different file entirely; the mark must not care.
		repo:write("d.txt", { "unrelated" })
		session:update(helpers.build(repo))

		local still_reviewed = false
		for _, entry in ipairs(session.order) do
			if entry.file.path == path and session:is_reviewed(entry.hunk) then
				still_reviewed = true
			end
		end

		assert.is_true(still_reviewed, "a mark must survive an edit to another file")
	end)

	it("drops a mark when that hunk's own content changes", function()
		local entry = session.order[1]
		session:mark(entry.hunk, true)
		assert.equals(1, select(1, session:progress()))

		-- Rewrite the very lines that were approved.
		repo:write(entry.file.path, { "COMPLETELY", "different", "content" })
		session:update(helpers.build(repo))

		for _, e in ipairs(session.order) do
			if e.file.path == entry.file.path then
				assert.is_false(
					session:is_reviewed(e.hunk),
					"rewriting reviewed lines must not stay reviewed"
				)
			end
		end
	end)
end)

describe("state persistence", function()
	local repo

	before_each(function()
		config.setup({})
		repo = helpers.repo()
		seed(repo)
	end)

	after_each(function()
		repo:destroy()
		config.setup({})
	end)

	it("writes under the git dir, keyed by revspec", function()
		local cs = helpers.build(repo)

		assert.is_truthy(state_store.path(cs):match("%.git/draven/worktree@HEAD%.json$"))
		assert.equals(
			"range@main...HEAD",
			state_store.key({
				revspec = { kind = "range", arg = "main...HEAD", base = "main" },
			})
		)
	end)

	it("round-trips marks across sessions", function()
		local session = session_mod.new(helpers.build(repo))
		local hash = session.order[1].hunk.content_hash

		session:mark(session.order[1].hunk, true)
		session:save()

		local reopened = session_mod.new(helpers.build(repo))
		assert.is_not_nil(reopened.state.reviewed[hash])
		assert.equals(1, select(1, reopened:progress()))
	end)

	it("starts fresh when the state file is corrupt", function()
		local cs = helpers.build(repo)
		local path = state_store.path(cs)

		vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
		vim.fn.writefile({ "{ this is not json" }, path)

		local session = session_mod.new(cs)
		assert.same({}, session.state.reviewed)
	end)

	it("starts fresh when the state file is from another version", function()
		local cs = helpers.build(repo)
		local path = state_store.path(cs)

		vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
		vim.fn.writefile(
			{ vim.json.encode({ version = 999, reviewed = { abc = { at = 1 } } }) },
			path
		)

		local session = session_mod.new(cs)
		assert.same({}, session.state.reviewed)
	end)

	it("migrates the old implicit collapsed state for resolved findings", function()
		local cs = helpers.build(repo)
		local path = state_store.path(cs)

		vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
		vim.fn.writefile({
			vim.json.encode({
				version = state_store.VERSION,
				reviewed = {},
				findings = { old = { resolved = true } },
			}),
		}, path)

		local state = state_store.load(cs)
		assert.is_true(state.findings.old.collapsed)
	end)

	it("keeps separate state per revspec", function()
		repo:commit("second")

		local worktree = state_store.path(helpers.build(repo))
		local range = state_store.path(helpers.build(repo, "HEAD~1..HEAD"))

		assert.are_not.equals(worktree, range)
	end)
end)
