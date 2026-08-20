---The diff window.
---
---Whenever the post-image exists on disk — the working-tree case, which is the
---one that matters for agent output — this shows the real file buffer. Content
---that has no file (a deleted file, or any path in a commit range) falls back
---to a read-only scratch buffer that still gets a filetype, so treesitter and
---syntax keep working there too.
local async = require("draven.util.async")
local config = require("draven.config")
local git = require("draven.core.git")
local hunk_mod = require("draven.core.hunk")
local render = require("draven.ui.render")

local M = {}

---@class draven.View
---@field win integer
---@field session draven.Session
---@field file draven.File|nil
---@field bufnr integer|nil
---@field scratch table<string, integer>
local View = {}
View.__index = View

---@param win integer
---@param session draven.Session
---@return draven.View
function M.new(win, session)
	return setmetatable({
		win = win,
		session = session,
		file = nil,
		bufnr = nil,
		scratch = {},
	}, View)
end

---Text shown on a folded region of unchanged code.
---@return string
function M.foldtext()
	local count = vim.v.foldend - vim.v.foldstart + 1
	return ("  ⋯ %d unchanged lines"):format(count)
end

---@param name string
---@param lines string[]
---@param filetype string|nil
---@return integer bufnr
function View:_scratch(name, lines, filetype)
	local existing = self.scratch[name]
	if existing and vim.api.nvim_buf_is_valid(existing) then
		vim.bo[existing].modifiable = true
		vim.api.nvim_buf_set_lines(existing, 0, -1, false, lines)
		vim.bo[existing].modifiable = false
		return existing
	end

	local bufnr = vim.api.nvim_create_buf(false, true)

	vim.bo[bufnr].buftype = "nofile"
	vim.bo[bufnr].bufhidden = "hide"
	vim.bo[bufnr].swapfile = false
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
	vim.bo[bufnr].modifiable = false
	vim.bo[bufnr].modified = false

	pcall(vim.api.nvim_buf_set_name, bufnr, name)

	if filetype then
		vim.bo[bufnr].filetype = filetype
	end

	self.scratch[name] = bufnr
	return bufnr
end

---@param path string
---@param bufnr integer
---@return string|nil
local function detect_filetype(path, bufnr)
	return vim.filetype.match({ filename = path, buf = bufnr })
end

---Resolve the buffer that should be displayed for `file`. Runs inside the
---async runtime because commit ranges and deleted files need `git show`.
---@param file draven.File
---@return integer bufnr
---@return boolean deleted_file
function View:_buffer_for(file)
	local cs = self.session.changeset

	if file.binary then
		return self:_scratch(
			"draven://binary/" .. file.path,
			{ "", ("  %s"):format(file.path), "", "  Binary file — nothing to read here." },
			nil
		),
			false
	end

	if file.skipped then
		return self:_scratch("draven://skipped/" .. file.path, {
			"",
			("  %s"):format(file.path),
			"",
			("  Not read: %s."):format(file.skipped),
		}, nil),
			false
	end

	-- Deleted: the only content is the pre-image, from the base revision.
	if file.status == "deleted" then
		local rev = cs.base_rev or cs.revspec.base
		local content = git.show(rev, file.old_path or file.path, cs.root)
		local lines = content and vim.split(content, "\n", { plain = true }) or { "" }
		if lines[#lines] == "" then
			table.remove(lines)
		end

		local name = ("draven://%s/%s"):format(rev:sub(1, 7), file.path)
		local bufnr = self:_scratch(name, lines, nil)
		vim.bo[bufnr].filetype = detect_filetype(file.path, bufnr) or ""
		return bufnr, true
	end

	-- A commit range never touches the working tree, so read the post-image
	-- out of the object database.
	if cs.revspec.kind == "range" then
		local rev = cs.revspec.head or "HEAD"
		local content = git.show(rev, file.path, cs.root)
		local lines = content and vim.split(content, "\n", { plain = true }) or { "" }
		if lines[#lines] == "" then
			table.remove(lines)
		end

		local name = ("draven://%s/%s"):format(rev, file.path)
		local bufnr = self:_scratch(name, lines, nil)
		vim.bo[bufnr].filetype = detect_filetype(file.path, bufnr) or ""
		return bufnr, false
	end

	-- The ordinary case: the real file, with everything that comes with it.
	local abs = cs.root .. "/" .. file.path
	local bufnr = vim.fn.bufadd(abs)
	vim.fn.bufload(bufnr)
	return bufnr, false
end

---@param win integer
local function apply_window_options(win)
	local ui = config.options.ui

	vim.wo[win].signcolumn = "yes:2"
	vim.wo[win].wrap = false

	vim.wo[win].foldmethod = "expr"
	vim.wo[win].foldexpr = "v:lua.require'draven.ui.render'.foldexpr()"
	vim.wo[win].foldtext = "v:lua.require'draven.ui.view'.foldtext()"
	vim.wo[win].foldlevel = 0
	vim.wo[win].fillchars = "fold: "
	vim.wo[win].foldenable = ui.fold_unchanged
end

---Display `file`, optionally putting the cursor on a particular hunk.
---@param file draven.File
---@param opts? { hunk?: draven.Hunk, lnum?: integer, on_done?: fun() }
function View:show(file, opts)
	opts = opts or {}

	async.run(function()
		return self:_buffer_for(file)
	end, function(err, bufnr, deleted_file)
		if err or not bufnr then
			require("draven.util.log").error(err or "could not open " .. file.path)
			return
		end

		if not vim.api.nvim_win_is_valid(self.win) then
			return
		end

		-- Stop decorating whatever we were showing before.
		if self.bufnr and self.bufnr ~= bufnr then
			render.clear(self.bufnr)
		end

		self.file = file
		self.bufnr = bufnr
		self.deleted_file = deleted_file

		vim.api.nvim_win_set_buf(self.win, bufnr)

		-- Decorate first: setting `foldexpr` makes Neovim evaluate it straight
		-- away, and it must see fold levels that already exist.
		self:redraw()
		apply_window_options(self.win)

		local lnum = opts.lnum
		if not lnum and opts.hunk then
			lnum = select(1, hunk_mod.new_range(opts.hunk))
			if lnum == 0 then
				lnum = math.max(1, opts.hunk.new_start)
			end
		end
		if not lnum then
			local first = file.hunks[1]
			lnum = first and select(1, hunk_mod.new_range(first)) or 1
			if lnum == 0 then
				lnum = 1
			end
		end

		self:goto_line(lnum)

		if opts.on_done then
			opts.on_done()
		end
	end)
end

---Repaint decorations for whatever is currently shown.
function View:redraw()
	if not self.file or not self.bufnr then
		return
	end
	if not vim.api.nvim_buf_is_valid(self.bufnr) then
		return
	end

	local width = vim.api.nvim_win_is_valid(self.win) and vim.api.nvim_win_get_width(self.win)
		or vim.o.columns

	render.render(self.bufnr, self.file, self.session, {
		width = width,
		deleted_file = self.deleted_file,
	})
end

---Make Neovim re-run `foldexpr`. Only needed when hunks actually moved — a
---plain mark leaves the geometry alone, and recomputing would throw away folds
---you opened by hand.
function View:recompute_folds()
	if not vim.api.nvim_win_is_valid(self.win) then
		return
	end

	vim.api.nvim_win_call(self.win, function()
		vim.wo.foldmethod = "manual"
		vim.wo.foldmethod = "expr"
	end)
end

---@param lnum integer
function View:goto_line(lnum)
	if not vim.api.nvim_win_is_valid(self.win) then
		return
	end

	local total = vim.api.nvim_buf_line_count(self.bufnr)
	lnum = math.max(1, math.min(lnum, total))

	vim.api.nvim_win_set_cursor(self.win, { lnum, 0 })

	-- Open the fold we just landed in, and centre it.
	vim.api.nvim_win_call(self.win, function()
		if vim.wo.foldenable and vim.fn.foldclosed(lnum) ~= -1 then
			vim.cmd("normal! zv")
		end
		vim.cmd("normal! zz")
	end)
end

---The hunk under the cursor, or the nearest one after it.
---@return draven.Hunk|nil
function View:hunk_at_cursor()
	if not self.file or not vim.api.nvim_win_is_valid(self.win) then
		return nil
	end

	local lnum = vim.api.nvim_win_get_cursor(self.win)[1]
	return self.session:hunk_at(self.file, lnum)
		or self.session:nearest_hunk(self.file, lnum, false)
		or self.session:nearest_hunk(self.file, lnum, true)
end

function View:close()
	for _, bufnr in pairs(self.scratch) do
		if vim.api.nvim_buf_is_valid(bufnr) then
			vim.api.nvim_buf_delete(bufnr, { force = true })
		end
	end
	self.scratch = {}

	if self.bufnr then
		render.clear(self.bufnr)
	end
end

M.View = View

return M
