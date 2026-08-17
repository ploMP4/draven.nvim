---User-facing configuration.
local M = {}

---@class draven.GitConfig
---@field bin string
---@field timeout_ms integer

---@class draven.IgnoreConfig
---@field enabled boolean
---@field patterns string[] # globs, see `draven.util.glob`

---@class draven.Config
---@field base string # default base revision for a working-tree review
---@field context integer # lines of context per hunk
---@field include_untracked boolean
---@field max_file_bytes integer # untracked files above this are listed, not read
---@field log_level integer
---@field git draven.GitConfig
---@field ignore draven.IgnoreConfig
local defaults = {
	base = "HEAD",
	context = 3,
	include_untracked = true,
	max_file_bytes = 1024 * 1024,
	log_level = vim.log.levels.INFO,

	git = {
		bin = "git",
		timeout_ms = 15000,
	},

	ignore = {
		enabled = true,
		-- Files whose diffs are noise. Ignored files stay visible in the
		-- changeset but are excluded from the review denominator, so a
		-- regenerated lockfile can never make progress look worse.
		patterns = {
			"**/*.lock",
			"**/package-lock.json",
			"**/pnpm-lock.yaml",
			"**/yarn.lock",
			"**/bun.lockb",
			"**/go.sum",
			"**/Cargo.lock",
			"**/poetry.lock",
			"**/composer.lock",
			"**/*.pb.go",
			"**/*_pb2.py",
			"**/*_generated.go",
			"**/*.generated.*",
			"**/*.min.js",
			"**/*.min.css",
			"**/*.snap",
			"**/node_modules/**",
			"**/vendor/**",
			"**/dist/**",
			"**/build/**",
		},
	},
}

---@type draven.Config
M.options = vim.deepcopy(defaults)

---Bumped on every `setup`, so derived caches can invalidate themselves.
M.generation = 0

---@return draven.Config
function M.defaults()
	return vim.deepcopy(defaults)
end

---@param opts? table
---@return draven.Config
function M.setup(opts)
	opts = opts or {}
	local merged = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts)

	-- `tbl_deep_extend` merges list-like tables index by index, which would
	-- leave stale defaults behind. Replace them wholesale instead.
	if opts.ignore and opts.ignore.patterns then
		merged.ignore.patterns = vim.deepcopy(opts.ignore.patterns)
	end

	M.options = merged
	M.generation = M.generation + 1
	return M.options
end

return M
