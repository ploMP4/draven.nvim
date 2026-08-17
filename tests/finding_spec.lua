local config = require("draven.config")
local export = require("draven.export")
local finding_mod = require("draven.finding")
local helpers = require("helpers")
local hunk_mod = require("draven.core.hunk")
local session_mod = require("draven.session")

---A file with three separated regions, so edits land in distinct hunks.
local function source(one, two, three)
	local lines = { "package auth", "" }

	local function region(n, marker)
		lines[#lines + 1] = ("func Region%d() string {"):format(n)
		lines[#lines + 1] = ("\treturn %q"):format(marker)
		lines[#lines + 1] = "}"
		for i = 1, 12 do
			lines[#lines + 1] = ("// padding %d.%d"):format(n, i)
		end
	end

	region(1, one)
	region(2, two)
	region(3, three)
	return lines
end

---@return draven.Session, table
local function fixture()
	local repo = helpers.repo()
	repo:write("auth/token.go", source("base", "base", "base"))
	repo:commit("init")
	repo:write("auth/token.go", source("v1-one", "v1-two", "v1-three"))
	return session_mod.new(helpers.build(repo)), repo
end

---The buffer line of the `return "<marker>"` line inside a hunk.
---@return draven.Hunk, integer
local function locate(session, marker)
	for _, entry in ipairs(session.order) do
		local image = hunk_mod.post_image(entry.hunk.lines)
		local lnums = hunk_mod.post_lnums(entry.hunk.lines)
		for i, line in ipairs(image) do
			if line:find(marker, 1, true) then
				return entry.hunk, lnums[i]
			end
		end
	end
	error("marker not found: " .. marker)
end

describe("finding.reanchor", function()
	local session, repo

	before_each(function()
		config.setup({})
		session, repo = fixture()
	end)

	after_each(function()
		repo:destroy()
		config.setup({})
	end)

	it("anchors to the line it was written against", function()
		local hunk, lnum = locate(session, "v1-two")
		local item = session:add_finding(hunk, lnum, { body = "check this", severity = "blocking" })

		assert.is_not_nil(item)
		assert.equals(lnum, item.lnum)
		assert.equals("anchored", item.state)
		assert.is_truthy(item.line_text:find("v1-two", 1, true))
	end)

	it("refuses to attach to a line outside any hunk", function()
		local hunk = session.order[1].hunk
		assert.is_nil(session:add_finding(hunk, 9999, { body = "x", severity = "nit" }))
	end)

	it("follows its line when unrelated edits shift it", function()
		local hunk, lnum = locate(session, "v1-three")
		local item = session:add_finding(hunk, lnum, { body = "check this", severity = "blocking" })

		-- Insert a block near the top: everything below moves down.
		local lines = source("v1-one", "v1-two", "v1-three")
		table.insert(lines, 3, "// a brand new comment line")
		table.insert(lines, 3, "// and another")
		repo:write("auth/token.go", lines)
		session:update(helpers.build(repo))

		local moved = session:findings()[1]
		assert.are_not.equals("orphaned", moved.state)
		assert.equals(lnum + 2, moved.lnum, "the finding should ride along with its line")
	end)

	it("survives a rewrite of the hunk it lives in", function()
		local hunk, lnum = locate(session, "v1-two")
		session:add_finding(hunk, lnum, { body = "no expiry check", severity = "blocking" })

		-- The agent revises a *different* line of the same region.
		local lines = source("v1-one", "v1-two", "v1-three")
		for i, line in ipairs(lines) do
			if line:find("Region2", 1, true) then
				lines[i] = "func Region2(ctx context.Context) string {"
			end
		end
		repo:write("auth/token.go", lines)
		session:update(helpers.build(repo))

		local item = session:findings()[1]
		assert.are_not.equals("orphaned", item.state, "the line it points at still exists")
		assert.is_not_nil(item.lnum)

		local file = session.changeset.files[1]
		local found = false
		for _, h in ipairs(file.hunks) do
			local image = hunk_mod.post_image(h.lines)
			local lnums = hunk_mod.post_lnums(h.lines)
			for i, l in ipairs(image) do
				if lnums[i] == item.lnum then
					found = l:find("v1-two", 1, true) ~= nil
				end
			end
		end
		assert.is_true(found, "it should still point at the line it was written about")
	end)

	it("orphans rather than lies when its line is deleted", function()
		local hunk, lnum = locate(session, "v1-two")
		session:add_finding(hunk, lnum, { body = "gone", severity = "blocking" })

		repo:write("auth/token.go", source("v1-one", "COMPLETELY-DIFFERENT", "v1-three"))
		session:update(helpers.build(repo))

		local item = session:findings()[1]
		assert.equals("orphaned", item.state)
		assert.is_nil(item.lnum)
		-- It still knows where it used to be, so it can be shown to you.
		assert.is_number(item.last_lnum)
	end)

	it("keeps findings when the file leaves the changeset", function()
		local hunk, lnum = locate(session, "v1-two")
		session:add_finding(hunk, lnum, { body = "still here", severity = "nit" })

		repo:write("auth/token.go", source("base", "base", "base"))
		session:update(helpers.build(repo))

		local items = session:findings()
		assert.equals(1, #items, "a finding is not lost just because the diff went away")
		assert.equals("orphaned", items[1].state)
	end)
end)

describe("findings", function()
	local session, repo

	before_each(function()
		config.setup({})
		session, repo = fixture()
	end)

	after_each(function()
		repo:destroy()
		config.setup({})
	end)

	local function add(marker, body, severity)
		local hunk, lnum = locate(session, marker)
		return session:add_finding(hunk, lnum, { body = body, severity = severity })
	end

	it("defaults to blocking and validates severity", function()
		assert.equals("blocking", finding_mod.normalize_severity(nil))
		assert.equals("blocking", finding_mod.normalize_severity("nonsense"))
		assert.equals("nit", finding_mod.normalize_severity("nit"))
	end)

	it("cycles severity", function()
		assert.equals("question", finding_mod.next_severity("blocking"))
		assert.equals("nit", finding_mod.next_severity("question"))
		assert.equals("blocking", finding_mod.next_severity("nit"))
	end)

	it("sorts blocking first", function()
		add("v1-one", "a nit", "nit")
		add("v1-two", "a question", "question")
		add("v1-three", "a blocker", "blocking")

		local items = session:findings()
		assert.equals("blocking", items[1].severity)
		assert.equals("question", items[2].severity)
		assert.equals("nit", items[3].severity)
	end)

	it("counts per file, excluding resolved", function()
		local a = add("v1-one", "one", "blocking")
		add("v1-two", "two", "nit")

		local total, unresolved = session:finding_counts("auth/token.go")
		assert.equals(2, total)
		assert.equals(2, unresolved)

		session:toggle_resolved(a.id)
		local _, after = session:finding_counts("auth/token.go")
		assert.equals(1, after)
	end)

	it("finds what sits on a line", function()
		local item = add("v1-two", "here", "blocking")
		assert.equals(1, #session:findings_at("auth/token.go", item.lnum))
		assert.equals(0, #session:findings_at("auth/token.go", item.lnum + 500))
	end)

	it("edits and deletes", function()
		local item = add("v1-two", "first draft", "nit")

		session:update_finding(item.id, "second draft", "blocking")
		assert.equals("second draft", session:findings()[1].body)
		assert.equals("blocking", session:findings()[1].severity)

		assert.is_true(session:remove_finding(item.id))
		assert.equals(0, #session:findings())
		assert.is_false(session:remove_finding("nope"))
	end)

	it("persists across sessions and re-anchors on load", function()
		local item = add("v1-two", "survives a restart", "question")
		session:save()

		local reopened = session_mod.new(helpers.build(repo))
		local items = reopened:findings()

		assert.equals(1, #items)
		assert.equals("survives a restart", items[1].body)
		assert.equals("question", items[1].severity)
		assert.equals(item.lnum, items[1].lnum)
		assert.equals("anchored", items[1].state)
	end)
end)

describe("export", function()
	local session, repo

	before_each(function()
		config.setup({})
		session, repo = fixture()
	end)

	after_each(function()
		repo:destroy()
		config.setup({})
	end)

	local function add(marker, body, severity)
		local hunk, lnum = locate(session, marker)
		return session:add_finding(hunk, lnum, { body = body, severity = severity })
	end

	it("produces nothing when there is nothing to say", function()
		local text, count = export.prompt(session)
		assert.equals(0, count)
		assert.equals("", text)
	end)

	it("writes a prompt grouped by severity", function()
		add("v1-one", "This leaks the token on error.", "blocking")
		add("v1-two", "Why is this exported?", "question")
		add("v1-three", "Spelling.", "nit")

		local text, count = export.prompt(session)
		assert.equals(3, count)

		assert.is_truthy(text:match("Blocking"))
		assert.is_truthy(text:match("Questions"))
		assert.is_truthy(text:match("Nits"))
		assert.is_truthy(text:match("This leaks the token on error%."))

		-- Blocking must come before nits in the output.
		assert.is_true(text:find("Blocking", 1, true) < text:find("Nits", 1, true))

		-- Every finding carries a location and a code excerpt.
		assert.is_truthy(text:match("### auth/token%.go:%d+"))
		assert.is_truthy(text:match("```go"))
		assert.is_truthy(text:match("Do not change anything else"))
	end)

	it("leaves resolved findings out by default", function()
		local a = add("v1-one", "fixed already", "blocking")
		add("v1-two", "still open", "blocking")
		session:toggle_resolved(a.id)

		local text, count = export.prompt(session)
		assert.equals(1, count)
		assert.is_falsy(text:match("fixed already"))
		assert.is_truthy(text:match("still open"))

		local all = export.prompt(session, { unresolved_only = false })
		assert.is_truthy(all:match("fixed already"))
	end)

	it("says so when a finding lost its line", function()
		add("v1-two", "orphan me", "blocking")
		repo:write("auth/token.go", source("v1-one", "REPLACED", "v1-three"))
		session:update(helpers.build(repo))

		local text = export.prompt(session)
		assert.is_truthy(text:match("line unknown"))
		assert.is_truthy(text:match("orphan me"))
	end)

	it("fills the quickfix list with severities as types", function()
		add("v1-one", "blocker", "blocking")
		add("v1-two", "question", "question")
		add("v1-three", "nit", "nit")

		local count = export.quickfix(session, { open = false })
		assert.equals(3, count)

		local list = vim.fn.getqflist()
		assert.equals(3, #list)
		assert.equals("E", list[1].type)
		assert.equals("W", list[2].type)
		assert.equals("I", list[3].type)
		assert.is_truthy(list[1].text:match("blocker"))
		assert.is_true(list[1].lnum > 0)
	end)

	it("writes to a register", function()
		add("v1-one", "copy me", "blocking")
		config.setup({ export = { register = "z" } })

		local text = export.prompt(session)
		assert.is_true(export.to_clipboard(text))
		assert.is_truthy(vim.fn.getreg("z"):match("copy me"))
	end)
end)
