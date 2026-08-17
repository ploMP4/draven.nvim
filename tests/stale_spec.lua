---The thesis, end to end: an agent edits one hunk of a reviewed file and
---only that hunk goes stale.
local config = require("draven.config")
local helpers = require("helpers")
local session_mod = require("draven.session")
local state_store = require("draven.state")

---A file with three well-separated regions, so edits land in distinct hunks.
---@param marker3 string
local function source(marker1, marker2, marker3)
	local lines = { "package auth", "" }

	local function region(n, marker)
		lines[#lines + 1] = ("func Region%d() string {"):format(n)
		lines[#lines + 1] = ("\treturn %q"):format(marker)
		lines[#lines + 1] = "}"
		for i = 1, 12 do
			lines[#lines + 1] = ("// padding %d.%d"):format(n, i)
		end
	end

	region(1, marker1)
	region(2, marker2)
	region(3, marker3)
	return lines
end

describe("stale detection", function()
	local repo, session

	before_each(function()
		config.setup({})
		repo = helpers.repo()

		repo:write("auth/token.go", source("base", "base", "base"))
		repo:commit("init")

		-- The agent's first pass touches all three regions.
		repo:write("auth/token.go", source("v1-one", "v1-two", "v1-three"))
		session = session_mod.new(helpers.build(repo))
	end)

	after_each(function()
		repo:destroy()
		config.setup({})
	end)

	it("sees three separate hunks", function()
		assert.equals(3, #session.order, "regions should not merge into one hunk")
	end)

	it("marks everything reviewed", function()
		session:mark_all(true)

		local reviewed, total, stale = session:progress()
		assert.equals(total, reviewed)
		assert.equals(0, stale)
	end)

	it("goes stale on exactly the rewritten hunk", function()
		session:mark_all(true)

		-- The agent revises one region and leaves the others alone.
		repo:write("auth/token.go", source("v1-one", "v2-REVISED", "v1-three"))
		session:update(helpers.build(repo))

		local by_status = { reviewed = 0, stale = 0, unread = 0 }
		local stale_hunk
		for _, entry in ipairs(session.order) do
			local status = session:hunk_state(entry.hunk)
			by_status[status] = by_status[status] + 1
			if status == "stale" then
				stale_hunk = entry.hunk
			end
		end

		assert.equals(1, by_status.stale, "exactly one hunk should be stale")
		assert.equals(2, by_status.reviewed, "the untouched hunks stay reviewed")
		assert.equals(0, by_status.unread)

		-- And it knows what it descends from.
		assert.is_not_nil(session:origin_of(stale_hunk))
	end)

	it("keeps the file's state honest when one hunk goes stale", function()
		session:mark_all(true)
		repo:write("auth/token.go", source("v1-one", "v2-REVISED", "v1-three"))
		session:update(helpers.build(repo))

		local file = session.changeset.files[1]
		assert.equals("stale", session:file_state(file), "a rewrite outranks partial progress")

		local reviewed, total, stale = session:file_progress(file)
		assert.equals(2, reviewed)
		assert.equals(3, total)
		assert.equals(1, stale)
	end)

	it("counts a stale hunk as still needing attention", function()
		session:mark_all(true)
		repo:write("auth/token.go", source("v1-one", "v2-REVISED", "v1-three"))
		session:update(helpers.build(repo))

		local reviewed, total = session:progress()
		assert.equals(2, reviewed)
		assert.equals(3, total)

		-- Navigation must land on it: stale is not "done".
		local entry = session:next_unread(nil, false)
		assert.is_not_nil(entry)
		assert.equals("stale", session:hunk_state(entry.hunk))

		local stale_entry = session:next_stale(nil, false)
		assert.equals(entry.hunk.id, stale_entry.hunk.id)
	end)

	it("stores the approved post-image and diffs the rewrite against it", function()
		session:mark_all(true)

		repo:write("auth/token.go", source("v1-one", "v2-REVISED", "v1-three"))
		session:update(helpers.build(repo))

		local stale_hunk
		for _, entry in ipairs(session.order) do
			if session:hunk_state(entry.hunk) == "stale" then
				stale_hunk = entry.hunk
			end
		end

		local approved = session:approved_image(stale_hunk)
		assert.is_not_nil(approved, "the version you approved must still be retrievable")

		local text = table.concat(approved, "\n")
		assert.is_truthy(text:match("v1%-two"), "snapshot should hold what was approved")
		assert.is_falsy(text:match("v2%-REVISED"), "snapshot must not hold the rewrite")

		-- And the current image is the rewrite.
		local now = table.concat(require("draven.core.hunk").post_image(stale_hunk.lines), "\n")
		assert.is_truthy(now:match("v2%-REVISED"))
	end)

	it("returns to reviewed once you read the new version", function()
		session:mark_all(true)
		repo:write("auth/token.go", source("v1-one", "v2-REVISED", "v1-three"))
		session:update(helpers.build(repo))

		local stale_hunk
		for _, entry in ipairs(session.order) do
			if session:hunk_state(entry.hunk) == "stale" then
				stale_hunk = entry.hunk
			end
		end

		session:mark(stale_hunk, true)
		assert.equals("reviewed", session:hunk_state(stale_hunk))

		local reviewed, total, stale = session:progress()
		assert.equals(total, reviewed)
		assert.equals(0, stale)
	end)

	it("treats a brand new change elsewhere as unread, not stale", function()
		session:mark_all(true)

		-- Append a whole new region: it descends from nothing.
		local lines = source("v1-one", "v1-two", "v1-three")
		vim.list_extend(lines, { "", "func Added() {}", "" })
		repo:write("auth/token.go", lines)
		session:update(helpers.build(repo))

		local unread = 0
		for _, entry in ipairs(session.order) do
			if session:hunk_state(entry.hunk) == "unread" then
				unread = unread + 1
			end
		end

		assert.equals(1, unread, "new code is unread; nothing was rewritten under you")
	end)

	it("survives reindentation without going stale", function()
		session:mark_all(true)

		local lines = source("v1-one", "v1-two", "v1-three")
		for i, line in ipairs(lines) do
			-- Tabs to spaces: same code, different bytes.
			lines[i] = line:gsub("^\t", "    ")
		end
		repo:write("auth/token.go", lines)
		session:update(helpers.build(repo))

		local reviewed, total, stale = session:progress()
		assert.equals(0, stale, "reindenting approved code must not look like a rewrite")
		assert.equals(total, reviewed)
	end)

	it("stops inferring descent once the base revision moves", function()
		session:mark_all(true)

		-- Commit the reviewed work: HEAD moves, so every old-side address the
		-- marks recorded now points somewhere else.
		repo:commit("ship it")
		repo:write("auth/token.go", source("v1-one", "v2-REVISED", "v1-three"))

		local moved = session_mod.new(helpers.build(repo))

		for _, entry in ipairs(moved.order) do
			assert.are_not.equals(
				"stale",
				moved:hunk_state(entry.hunk),
				"descent cannot be proven against a base that moved"
			)
		end

		-- The recorded addresses are dropped rather than left lying.
		for _, record in pairs(moved.state.reviewed) do
			assert.is_nil(record.old_start)
		end
	end)
end)

describe("snapshots", function()
	local repo, session

	before_each(function()
		config.setup({})
		repo = helpers.repo()
		repo:write("a.txt", { "one", "two", "three" })
		repo:commit("init")
		repo:write("a.txt", { "one", "CHANGED", "three" })
		session = session_mod.new(helpers.build(repo))
	end)

	after_each(function()
		repo:destroy()
		config.setup({})
	end)

	it("writes one file per approved hunk, content-addressed", function()
		local hunk = session.order[1].hunk
		session:mark(hunk, true)

		local path = state_store.snapshot_path(session.changeset, hunk.content_hash)
		assert.equals(1, vim.fn.filereadable(path))

		assert.same(
			require("draven.core.hunk").post_image(hunk.lines),
			state_store.read_snapshot(session.changeset, hunk.content_hash)
		)
	end)

	it("skips hunks larger than the cap but still tracks them", function()
		config.setup({ max_snapshot_bytes = 8 })

		local hunk = session.order[1].hunk
		session:mark(hunk, true)

		assert.equals("reviewed", session:hunk_state(hunk))
		assert.is_nil(state_store.read_snapshot(session.changeset, hunk.content_hash))
	end)

	it("keeps each review target's snapshots apart", function()
		local worktree = state_store.snapshot_dir(session.changeset)
		repo:commit("second")
		local range = state_store.snapshot_dir(helpers.build(repo, "HEAD~1..HEAD"))

		assert.are_not.equals(
			worktree,
			range,
			"pruning one review must not be able to reach another's snapshots"
		)
	end)

	it("prunes snapshots no mark refers to", function()
		local hunk = session.order[1].hunk
		session:mark(hunk, true)
		session:save()

		local orphan = state_store.snapshot_path(session.changeset, "deadbeef")
		vim.fn.writefile({ "stale bytes" }, orphan)

		local removed = state_store.prune_snapshots(session.changeset, session.state)

		assert.equals(1, removed)
		assert.equals(0, vim.fn.filereadable(orphan))
		assert.equals(
			1,
			vim.fn.filereadable(state_store.snapshot_path(session.changeset, hunk.content_hash)),
			"a referenced snapshot must survive pruning"
		)
	end)

	it("records the base-side address a mark can be traced from", function()
		local hunk = session.order[1].hunk
		session:mark(hunk, true)

		local record = session.state.reviewed[hunk.content_hash]
		assert.equals(hunk.old_start, record.old_start)
		assert.equals(hunk.old_count, record.old_count)
		assert.equals(hunk.anchor_key, record.anchor_key)
		assert.equals("a.txt", record.path)
	end)
end)
