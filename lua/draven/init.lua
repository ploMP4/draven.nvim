---draven — a code review surface for Neovim that remembers what you read.
local async = require("draven.util.async")

local M = {}

M.version = "0.2.0"

---@param opts? table
function M.setup(opts)
	require("draven.config").setup(opts)
end

---Build a changeset.
---
---Called with a callback it runs asynchronously; called without one it blocks
---until the result is ready, which is convenient from `:lua` and tests but
---must not be done from a mapping or autocmd.
---
---@param opts? { rev?: string, cwd?: string }
---@param cb? fun(err: string|nil, cs: draven.Changeset|nil)
---@return draven.Changeset|nil # only when called without a callback
function M.changeset(opts, cb)
	if type(opts) == "function" then
		opts, cb = nil, opts
	end

	local function build()
		return require("draven.core.changeset").build(opts)
	end

	if cb then
		async.run(build, cb)
		return nil
	end

	return async.block(build)
end

---@param cs draven.Changeset
---@return string
function M.summary(cs)
	local s = cs.stats

	local scope
	if cs.revspec.kind == "range" then
		scope = cs.revspec.arg
	elseif cs.unborn then
		scope = "working tree (no commits yet)"
	else
		scope = ("working tree ← %s"):format(cs.revspec.base)
	end

	local parts = {
		("%d file%s"):format(s.files, s.files == 1 and "" or "s"),
		("%d hunk%s"):format(s.hunks, s.hunks == 1 and "" or "s"),
		("+%d/-%d"):format(s.added, s.removed),
	}

	if s.ignored_files > 0 then
		parts[#parts + 1] = ("%d ignored"):format(s.ignored_files)
	end
	if s.binary_files > 0 then
		parts[#parts + 1] = ("%d binary"):format(s.binary_files)
	end

	return ("%s · %s"):format(scope, table.concat(parts, " · "))
end

local STATUS_MARK = {
	added = "A",
	modified = "M",
	deleted = "D",
	renamed = "R",
	copied = "C",
	mode = "T",
}

---One line per file, in the shape the panel renders.
---@param cs draven.Changeset
---@return string[]
function M.lines(cs)
	local out = {}

	for _, f in ipairs(cs.files) do
		local name = f.old_path and ("%s ← %s"):format(f.path, f.old_path) or f.path

		local detail
		if f.ignored then
			detail = "ignored"
		elseif f.binary then
			detail = "binary"
		elseif f.skipped then
			detail = f.skipped
		elseif #f.hunks == 0 then
			detail = f.status == "mode" and ("mode %s → %s"):format(f.old_mode or "?", f.new_mode or "?")
				or "no content change"
		else
			detail = ("%d hunk%s  +%d/-%d"):format(
				#f.hunks,
				#f.hunks == 1 and "" or "s",
				f.added,
				f.removed
			)
		end

		-- Pad by display width: `←` is multibyte, so `%-48s` would drift.
		local pad = math.max(1, 48 - vim.fn.strdisplaywidth(name))
		out[#out + 1] = ("  %s  %s%s %s"):format(
			STATUS_MARK[f.status] or "?",
			name,
			string.rep(" ", pad),
			detail
		)
	end

	return out
end

---Open the review surface, or focus it if it is already open.
---@param opts? { rev?: string, cwd?: string }
function M.open(opts)
	require("draven.ui").open(opts)
end

function M.close()
	require("draven.ui").close()
end

---@param opts? { rev?: string, cwd?: string }
function M.toggle(opts)
	require("draven.ui").toggle(opts)
end

---@return boolean
function M.is_open()
	return require("draven.ui").is_open()
end

---Print a changeset summary without opening anything. Backs `:DravenStatus`.
---@param rev? string
---@param opts? { verbose?: boolean }
function M.status(rev, opts)
	opts = opts or {}
	local log = require("draven.util.log")

	M.changeset({ rev = rev }, function(err, cs)
		if err or not cs then
			log.error(err or "changeset build returned nothing")
			return
		end

		if #cs.files == 0 then
			log.info("no changes to review")
			return
		end

		if not opts.verbose then
			log.info(M.summary(cs))
			return
		end

		local report = { "draven — " .. M.summary(cs) }
		vim.list_extend(report, M.lines(cs))
		vim.schedule(function()
			vim.api.nvim_echo({ { table.concat(report, "\n") } }, true, {})
		end)
	end)
end

return M
