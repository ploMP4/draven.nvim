---Shared test scaffolding: throwaway git repositories on disk.
---
---These tests exercise real plumbing, because the parser being right does not
---prove the wiring is.
local async = require("draven.util.async")

local M = {}

local Repo = {}
Repo.__index = Repo

---@return table
function M.repo()
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
	assert(res.code == 0, ("git %s failed: %s"):format(table.concat(args, " "), res.stderr or ""))
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
---async runtime. This drives it to completion for the assertions.
---@param repo table
---@param rev? string
---@return draven.Changeset
function M.build(repo, rev)
	return async.block(function()
		return require("draven.core.changeset").build({ cwd = repo.dir, rev = rev })
	end)
end

---Wait for a predicate, failing the test rather than hanging.
---@param predicate fun(): boolean
---@param what string
function M.wait_for(predicate, what)
	local ok = vim.wait(15000, predicate, 10)
	assert(ok, "timed out waiting for " .. what)
end

return M
