local async = require("draven.util.async")
local changeset = require("draven.core.changeset")
local config = require("draven.config")
local draven = require("draven")

---A throwaway git repository on disk. These tests exercise real plumbing,
---because the parser being right does not prove the wiring is.
local Repo = {}
Repo.__index = Repo

function Repo.new()
	local dir = vim.fn.tempname()
	vim.fn.mkdir(dir, "p")

	local self = setmetatable({ dir = dir }, Repo)
	self:git({ "init", "-q", "-b", "main" })
	self:git({ "config", "user.email", "test@draven.test" })
	self:git({ "config", "user.name", "draven test" })
	self:git({ "config", "commit.gpgsign", "false" })
	return self
end

function Repo:git(args)
	local cmd = { "git" }
	vim.list_extend(cmd, args)

	local res = vim.system(cmd, { cwd = self.dir }):wait()
	assert(
		res.code == 0,
		("git %s failed: %s"):format(table.concat(args, " "), res.stderr or "")
	)
	return res.stdout or ""
end

function Repo:write(path, lines)
	local abs = self.dir .. "/" .. path
	vim.fn.mkdir(vim.fn.fnamemodify(abs, ":h"), "p")
	vim.fn.writefile(lines, abs)
end

function Repo:remove(path)
	vim.fn.delete(self.dir .. "/" .. path)
end

function Repo:commit(message)
	self:git({ "add", "-A" })
	self:git({ "commit", "-q", "-m", message })
end

function Repo:destroy()
	vim.fn.delete(self.dir, "rf")
end

---`changeset.build` suspends on every git call, so it only runs inside the
---async runtime. `block` drives it to completion for the assertions.
---@param repo table
---@param rev? string
---@return draven.Changeset
local function build(repo, rev)
	return async.block(function()
		return changeset.build({ cwd = repo.dir, rev = rev })
	end)
end

describe("changeset.parse_revspec", function()
	before_each(function()
		config.setup({})
	end)

	it("defaults to the working tree against HEAD", function()
		local spec = changeset.parse_revspec(nil)
		assert.equals("worktree", spec.kind)
		assert.equals("HEAD", spec.base)
		assert.is_nil(spec.head)
	end)

	it("treats a bare revision as a working-tree comparison", function()
		local spec = changeset.parse_revspec("main")
		assert.equals("worktree", spec.kind)
		assert.equals("main", spec.base)
	end)

	it("parses a two-dot range", function()
		local spec = changeset.parse_revspec("HEAD~3..HEAD")
		assert.equals("range", spec.kind)
		assert.equals("HEAD~3", spec.base)
		assert.equals("HEAD", spec.head)
		assert.is_false(spec.symmetric)
	end)

	it("parses a three-dot range", function()
		local spec = changeset.parse_revspec("main...HEAD")
		assert.equals("range", spec.kind)
		assert.equals("main", spec.base)
		assert.equals("HEAD", spec.head)
		assert.is_true(spec.symmetric)
	end)

	it("fills in HEAD for an open-ended range", function()
		local spec = changeset.parse_revspec("main..")
		assert.equals("range", spec.kind)
		assert.equals("main", spec.base)
		assert.equals("HEAD", spec.head)
	end)
end)

describe("changeset.build", function()
	local repo

	before_each(function()
		config.setup({})
		repo = Repo.new()
	end)

	after_each(function()
		repo:destroy()
		config.setup({})
	end)

	it("returns an empty changeset for a clean tree", function()
		repo:write("a.txt", { "one", "two" })
		repo:commit("init")

		local cs = build(repo)
		assert.equals(0, #cs.files)
		assert.equals(0, cs.stats.files)
		assert.equals(0, cs.stats.hunks)
	end)

	it("handles a repository with no commits", function()
		repo:write("a.txt", { "one" })

		local cs = build(repo)
		assert.is_true(cs.unborn)
		assert.equals(1, #cs.files)
		assert.equals("a.txt", cs.files[1].path)
		assert.equals("added", cs.files[1].status)
	end)

	it("finds files and hunks for uncommitted edits", function()
		repo:write("auth/token.go", {
			"package auth",
			"",
			"func Validate(tok string) error {",
			"\tif tok == \"\" {",
			"\t\treturn ErrEmpty",
			"\t}",
			"\treturn nil",
			"}",
		})
		repo:commit("init")

		repo:write("auth/token.go", {
			"package auth",
			"",
			"func Validate(tok string) error {",
			"\tif strings.TrimSpace(tok) == \"\" {",
			"\t\treturn ErrEmpty",
			"\t}",
			"\treturn nil",
			"}",
		})

		local cs = build(repo)

		assert.equals(1, #cs.files)
		assert.equals(1, cs.stats.files)
		assert.equals(1, cs.stats.hunks)
		assert.equals(1, cs.stats.added)
		assert.equals(1, cs.stats.removed)

		local f = cs.files[1]
		assert.equals("auth/token.go", f.path)
		assert.equals("modified", f.status)
		assert.equals(1, #f.hunks)

		local h = f.hunks[1]
		assert.is_string(h.content_hash)
		assert.is_string(h.anchor_key)
		assert.equals(64, #h.content_hash)
		assert.equals("auth/token.go#1", h.id)
	end)

	it("includes untracked files as additions", function()
		repo:write("a.txt", { "one" })
		repo:commit("init")

		repo:write("brand/new.txt", { "alpha", "beta", "gamma" })

		local cs = build(repo)
		local f = changeset.file(cs, "brand/new.txt")

		assert.is_not_nil(f)
		assert.is_true(f.untracked)
		assert.equals("added", f.status)
		assert.equals(3, f.added)
		assert.equals(1, #f.hunks)
		assert.equals(3, f.hunks[1].new_count)
		assert.same({ "alpha", "beta", "gamma" }, require("draven.core.hunk").post_image(f.hunks[1].lines))
	end)

	it("can leave untracked files out", function()
		repo:write("a.txt", { "one" })
		repo:commit("init")
		repo:write("untracked.txt", { "x" })

		config.setup({ include_untracked = false })

		local cs = build(repo)
		assert.is_nil(changeset.file(cs, "untracked.txt"))
	end)

	it("respects .gitignore for untracked files", function()
		repo:write(".gitignore", { "secret.txt" })
		repo:commit("init")
		repo:write("secret.txt", { "hunter2" })

		local cs = build(repo)
		assert.is_nil(changeset.file(cs, "secret.txt"))
	end)

	it("keeps ignored files visible but out of the totals", function()
		repo:write("go.sum", { "old" })
		repo:write("main.go", { "package main" })
		repo:commit("init")

		repo:write("go.sum", { "new", "lines", "here" })
		repo:write("main.go", { "package main", "// changed" })

		local cs = build(repo)

		assert.equals(2, #cs.files)
		assert.equals(1, cs.stats.files, "only main.go counts")
		assert.equals(1, cs.stats.ignored_files)

		local lock = changeset.file(cs, "go.sum")
		assert.is_true(lock.ignored)
		assert.is_true(#lock.hunks > 0, "an ignored file still carries its hunks")
	end)

	it("reports deletions", function()
		repo:write("gone.txt", { "a", "b" })
		repo:commit("init")
		repo:remove("gone.txt")

		local cs = build(repo)
		local f = changeset.file(cs, "gone.txt")

		assert.equals("deleted", f.status)
		assert.equals(2, f.removed)
	end)

	it("detects renames", function()
		repo:write("old.txt", {
			"line one",
			"line two",
			"line three",
			"line four",
			"line five",
		})
		repo:commit("init")

		repo:git({ "mv", "old.txt", "new.txt" })

		local cs = build(repo)
		local f = changeset.file(cs, "new.txt")

		assert.is_not_nil(f)
		assert.equals("renamed", f.status)
		assert.equals("old.txt", f.old_path)
	end)

	it("flags binary files without hunks", function()
		repo:write("a.txt", { "one" })
		repo:commit("init")

		local fd = assert(io.open(repo.dir .. "/blob.bin", "wb"))
		fd:write("\0\1\2\3binary\0content")
		fd:close()

		local cs = build(repo)
		local f = changeset.file(cs, "blob.bin")

		assert.is_true(f.binary)
		assert.equals(0, #f.hunks)
	end)

	it("compares a commit range", function()
		repo:write("a.txt", { "one" })
		repo:commit("first")
		repo:write("a.txt", { "one", "two" })
		repo:commit("second")
		repo:write("a.txt", { "one", "two", "three" })
		repo:commit("third")

		local cs = build(repo, "HEAD~2..HEAD")

		assert.equals("range", cs.revspec.kind)
		assert.equals(1, #cs.files)
		assert.equals(2, cs.stats.added)
		-- A range never reaches the working tree, so no untracked files.
		assert.is_nil(cs.base_rev)
	end)

	it("rejects a revision that does not exist", function()
		repo:write("a.txt", { "one" })
		repo:commit("init")

		local ok, err = pcall(build, repo, "no-such-branch")
		assert.is_false(ok)
		assert.is_truthy(tostring(err):match("cannot resolve revision"))
	end)

	it("errors outside a repository", function()
		local dir = vim.fn.tempname()
		vim.fn.mkdir(dir, "p")

		local ok, err = pcall(async.block, function()
			return changeset.build({ cwd = dir })
		end)
		vim.fn.delete(dir, "rf")

		assert.is_false(ok)
		assert.is_truthy(tostring(err):match("not inside a git repository"))
	end)

	it("iterates hunks across files, skipping ignored ones", function()
		repo:write("a.txt", { "one" })
		repo:write("go.sum", { "one" })
		repo:commit("init")

		repo:write("a.txt", { "changed" })
		repo:write("go.sum", { "changed" })
		repo:write("b.txt", { "brand new" })

		local cs = build(repo)

		local seen = {}
		for file, h in changeset.hunks(cs) do
			seen[#seen + 1] = file.path .. "#" .. h.index
		end

		assert.same({ "a.txt#1", "b.txt#1" }, seen)
	end)

	it("sorts files by path", function()
		repo:write("z.txt", { "one" })
		repo:write("a.txt", { "one" })
		repo:write("m.txt", { "one" })
		repo:commit("init")

		repo:write("z.txt", { "two" })
		repo:write("a.txt", { "two" })
		repo:write("m.txt", { "two" })

		local cs = build(repo)
		assert.same({ "a.txt", "m.txt", "z.txt" }, vim.tbl_map(function(f)
			return f.path
		end, cs.files))
	end)
end)

describe("draven public api", function()
	local repo

	before_each(function()
		config.setup({})
		repo = Repo.new()
	end)

	after_each(function()
		repo:destroy()
		config.setup({})
	end)

	it("returns a changeset when called without a callback", function()
		repo:write("a.txt", { "one" })
		repo:commit("init")
		repo:write("a.txt", { "two" })

		local cs = draven.changeset({ cwd = repo.dir })

		assert.is_not_nil(cs)
		assert.equals(1, #cs.files)
		assert.equals(1, #cs.files[1].hunks)
	end)

	it("delivers a changeset to a callback", function()
		repo:write("a.txt", { "one" })
		repo:commit("init")
		repo:write("a.txt", { "two" })

		local result, failure
		draven.changeset({ cwd = repo.dir }, function(err, cs)
			failure, result = err, cs
		end)

		vim.wait(10000, function()
			return result ~= nil or failure ~= nil
		end, 10)

		assert.is_nil(failure)
		assert.equals(1, #result.files)
	end)

	it("reports errors through the callback instead of throwing", function()
		local dir = vim.fn.tempname()
		vim.fn.mkdir(dir, "p")

		local done, failure = false, nil
		draven.changeset({ cwd = dir }, function(err)
			done, failure = true, err
		end)

		vim.wait(10000, function()
			return done
		end, 10)
		vim.fn.delete(dir, "rf")

		assert.is_truthy(failure)
		assert.is_truthy(tostring(failure):match("not inside a git repository"))
	end)

	it("summarises a changeset", function()
		repo:write("a.txt", { "one" })
		repo:commit("init")
		repo:write("a.txt", { "one", "two" })

		local cs = draven.changeset({ cwd = repo.dir })
		local summary = draven.summary(cs)

		assert.is_truthy(summary:match("1 file"))
		assert.is_truthy(summary:match("1 hunk"))
		assert.is_truthy(summary:match("%+1/%-0"))
	end)

	it("renders one line per file", function()
		repo:write("a.txt", { "one" })
		repo:commit("init")
		repo:write("a.txt", { "two" })
		repo:write("new.txt", { "x" })

		local cs = draven.changeset({ cwd = repo.dir })
		local lines = draven.lines(cs)

		assert.equals(2, #lines)
		assert.is_truthy(lines[1]:match("M%s+a%.txt"))
		assert.is_truthy(lines[2]:match("A%s+new%.txt"))
	end)
end)
