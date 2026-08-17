---Async git plumbing.
---
---Every function here must be called inside `async.run`. Output is handled as
---raw bytes rather than `text = true`, because that option rewrites CRLF and
---would change the content hashes a review's state is keyed on.
local async = require("draven.util.async")
local config = require("draven.config")

local M = {}

---The hash of git's empty tree. Diffing against it turns "every tracked file"
---into "one big addition", which is what an unborn HEAD needs.
M.EMPTY_TREE = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

---@class draven.GitResult
---@field code integer
---@field stdout string
---@field stderr string

---@param args string[]
---@param opts? { cwd?: string, check?: boolean }
---@return draven.GitResult
function M.exec(args, opts)
	opts = opts or {}
	local cfg = config.options.git

	local cmd = { cfg.bin, "-c", "core.quotePath=false", "--no-pager" }
	vim.list_extend(cmd, args)

	local res = async.await(function(resume)
		local ok, err = pcall(vim.system, cmd, {
			cwd = opts.cwd,
			timeout = cfg.timeout_ms,
		}, function(out)
			vim.schedule(function()
				resume(out)
			end)
		end)

		if not ok then
			vim.schedule(function()
				resume({ code = -1, stdout = "", stderr = tostring(err) })
			end)
		end
	end)

	local result = {
		code = res.code or -1,
		stdout = res.stdout or "",
		stderr = res.stderr or "",
	}

	if opts.check ~= false and result.code ~= 0 then
		error(
			("draven: `git %s` failed (exit %d): %s"):format(
				table.concat(args, " "),
				result.code,
				vim.trim(result.stderr) ~= "" and vim.trim(result.stderr) or "no stderr"
			),
			0
		)
	end

	return result
end

---@param cwd? string
---@return string # absolute path to the work tree root
function M.root(cwd)
	local out = M.exec({ "rev-parse", "--show-toplevel" }, { cwd = cwd, check = false })
	if out.code ~= 0 then
		error(("draven: not inside a git repository (%s)"):format(cwd or vim.fn.getcwd()), 0)
	end
	return vim.trim(out.stdout)
end

---@param cwd? string
---@return string
function M.git_dir(cwd)
	return vim.trim(M.exec({ "rev-parse", "--absolute-git-dir" }, { cwd = cwd }).stdout)
end

---Resolve a revision to a commit sha, or nil if it does not exist.
---@param rev string
---@param cwd? string
---@return string|nil
function M.resolve(rev, cwd)
	local out = M.exec({ "rev-parse", "--verify", "--quiet", rev .. "^{commit}" }, {
		cwd = cwd,
		check = false,
	})
	if out.code ~= 0 then
		return nil
	end
	local sha = vim.trim(out.stdout)
	return sha ~= "" and sha or nil
end

---@param revargs string[] # e.g. { "HEAD" } or { "main...HEAD" }
---@param cwd string
---@return string # raw unified diff
function M.diff(revargs, cwd)
	local args = {
		"diff",
		"--no-color",
		"--no-ext-diff",
		"--find-renames",
		"-U" .. tostring(config.options.context),
	}
	vim.list_extend(args, revargs)
	args[#args + 1] = "--"
	return M.exec(args, { cwd = cwd }).stdout
end

---@param cwd string
---@return string[] # repo-relative paths
function M.untracked(cwd)
	local out = M.exec({ "ls-files", "--others", "--exclude-standard", "-z" }, { cwd = cwd })
	local paths = {}
	for _, p in ipairs(vim.split(out.stdout, "\0", { plain = true })) do
		if p ~= "" then
			paths[#paths + 1] = p
		end
	end
	return paths
end

---Read a blob at a revision. Returns nil when the path does not exist there.
---@param rev string
---@param path string
---@param cwd string
---@return string|nil
function M.show(rev, path, cwd)
	local out = M.exec({ "show", ("%s:%s"):format(rev, path) }, { cwd = cwd, check = false })
	if out.code ~= 0 then
		return nil
	end
	return out.stdout
end

---@param cwd? string
---@return string|nil # e.g. "2.51.0"
function M.version(cwd)
	local out = M.exec({ "--version" }, { cwd = cwd, check = false })
	if out.code ~= 0 then
		return nil
	end
	return out.stdout:match("(%d+%.%d+%.%d+)")
end

return M
