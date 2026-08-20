---User-facing configuration.
local M = {}

---@class draven.GitConfig
---@field bin string
---@field timeout_ms integer

---@class draven.IgnoreConfig
---@field enabled boolean
---@field patterns string[] # globs, see `draven.util.glob`

---@class draven.PanelConfig
---@field width integer
---@field position "left"|"right"

---@class draven.SignsConfig
---@field reviewed string
---@field unread string
---@field partial string
---@field ignored string
---@field hunk string

---@class draven.UiConfig
---@field panel draven.PanelConfig
---@field signs draven.SignsConfig
---@field finding_display "below"|"above"|"eol"|false
---@field max_inline_deletions integer
---@field fold_unchanged boolean
---@field fold_context integer

---@class draven.Config
---@field base string # default base revision for a working-tree review
---@field context integer # lines of context per hunk
---@field include_untracked boolean
---@field max_file_bytes integer # untracked files above this are listed, not read
---@field log_level integer
---@field git draven.GitConfig
---@field ignore draven.IgnoreConfig
---@field ui draven.UiConfig
---@field keymaps table<string, string|false>
local defaults = {
	base = "HEAD",
	context = 3,
	include_untracked = true,
	max_file_bytes = 1024 * 1024,
	-- Approved hunks larger than this are still tracked, but without a stored
	-- post-image there is nothing to show a v1→v2 delta against.
	max_snapshot_bytes = 256 * 1024,
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

	ui = {
		panel = {
			width = 38,
			position = "left",
			-- Uses nvim-web-devicons when it is installed, and reads fine
			-- without it.
			icons = true,
		},

		signs = {
			reviewed = "✓",
			unread = "○",
			partial = "◐",
			stale = "↻",
			ignored = "⊘",
			hunk = "╎",
			-- The bar marking a hunk's extent.
			bar = "▎",
			-- A second sign column carries these, so added and removed lines
			-- read as a diff even when a colorscheme's DiffAdd and DiffDelete
			-- backgrounds look alike.
			add = "+",
			delete = "-",
		},

		delta = {
			max_width = 110,
			max_height = 30,
			border = "rounded",
		},

		comment = {
			width = 76,
			height = 8,
			border = "rounded",
		},

		-- 0 is opaque. Floats inherit your NormalFloat either way.
		winblend = 0,

		-- Findings sit below their source line so annotations never obscure the
		-- code they describe. "above" and "eol" remain available.
		finding_display = "below",

		-- Virtual lines cannot be cursor-scrolled when a deletion is taller
		-- than the window. Keep the inline preview bounded; <leader>rd opens
		-- the complete hunk in a normal scrollable buffer.
		max_inline_deletions = 8,

		-- Unchanged code folds away so a 900-line file with three hunks reads
		-- as three hunks. `zR` opens everything, as always.
		fold_unchanged = true,
		fold_context = 6,
	},

	export = {
		-- `+` is the system clipboard; `"` the unnamed register.
		register = "+",
		-- Resolved findings stay in the state file but leave the prompt.
		unresolved_only = true,
	},

	findings = {
		-- New findings start here; cycle with <Tab> while composing.
		default_severity = "blocking",
	},

	-- Buffer-local to the review tab. Set any entry to `false` to skip it.
	-- A global mapping for opening a review is left to you; see the README.
	keymaps = {
		mark_hunk = "<leader>rr",
		unmark_hunk = "<leader>ru",
		next_hunk = "<leader>rn",
		prev_hunk = "<leader>rp",
		delta = "<leader>rd",
		comment = "<leader>rc",
		list_findings = "<leader>rq",
		export = "<leader>rx",
		toggle_resolved = "<leader>rt",
		toggle_finding = "<leader>rv",
		delete_finding = "<leader>rX",
		refresh = "<leader>rR",
		toggle_panel = "<leader>rw",
		open_entry = "<CR>",
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

	-- `false` disables a keymap, but `tbl_deep_extend` drops false values.
	if opts.keymaps then
		for action, lhs in pairs(opts.keymaps) do
			merged.keymaps[action] = lhs
		end
	end

	M.options = merged
	M.generation = M.generation + 1
	return M.options
end

return M
