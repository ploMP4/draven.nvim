---The review tabpage: panel, diff window, keymaps and the actions they call.
local config = require("draven.config")
local changeset_mod = require("draven.core.changeset")
local highlights = require("draven.ui.highlights")
local hunk_mod = require("draven.core.hunk")
local log = require("draven.util.log")
local panel_mod = require("draven.ui.panel")
local render = require("draven.ui.render")
local session_mod = require("draven.session")
local view_mod = require("draven.ui.view")

local M = {}

---@class draven.Review
---@field tabpage integer
---@field panel_win integer
---@field view_win integer
---@field panel draven.Panel
---@field view draven.View
---@field session draven.Session
---@field rev string|nil
---@field mapped integer[] # buffers we attached keymaps to

---@type draven.Review|nil
local active = nil

--- Keymaps -------------------------------------------------------------------

---@class draven.Action
---@field desc string
---@field fn fun()

---@type table<string, draven.Action>
local actions = {}

---Actions that only make sense in the panel. `<CR>` in particular must never
---be mapped into a real file buffer.
local PANEL_ONLY = { open_entry = true }

---@param bufnr integer
---@param opts? { panel?: boolean }
local function attach_keymaps(bufnr, opts)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end
	local is_panel = opts and opts.panel or false

	for name, lhs in pairs(config.options.keymaps) do
		local action = actions[name]
		if action and lhs and (is_panel or not PANEL_ONLY[name]) then
			vim.keymap.set("n", lhs, action.fn, {
				buffer = bufnr,
				desc = action.desc,
				nowait = true,
				silent = true,
			})
		end
	end
end

---@param bufnr integer
local function detach_keymaps(bufnr)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	for _, lhs in pairs(config.options.keymaps) do
		if lhs then
			pcall(vim.keymap.del, "n", lhs, { buffer = bufnr })
		end
	end
end

---Track a buffer so its mappings come off again when the review closes.
---@param bufnr integer
local function remember_mapped(bufnr)
	if not active then
		return
	end
	for _, existing in ipairs(active.mapped) do
		if existing == bufnr then
			return
		end
	end
	active.mapped[#active.mapped + 1] = bufnr
end

--- Helpers -------------------------------------------------------------------

---@param hunk draven.Hunk
---@return integer
local function hunk_line(hunk)
	local first = select(1, hunk_mod.new_range(hunk))
	return first == 0 and math.max(1, hunk.new_start) or first
end

local function repaint_panel()
	if not active then
		return
	end
	active.panel:render(active.session, active.view.file and active.view.file.path)
end

---Put the panel cursor on the file the diff window is showing.
local function sync_panel_cursor()
	if not active or not active.view.file then
		return
	end
	if not vim.api.nvim_win_is_valid(active.panel_win) then
		return
	end

	local lnum = active.panel:line_of(active.view.file.path)
	if lnum then
		pcall(vim.api.nvim_win_set_cursor, active.panel_win, { lnum, 0 })
	end
end

local function focus_view()
	if active and vim.api.nvim_win_is_valid(active.view_win) then
		vim.api.nvim_set_current_win(active.view_win)
	end
end

---@param file draven.File
---@param opts? { hunk?: draven.Hunk, focus?: boolean }
local function show_file(file, opts)
	opts = opts or {}
	if not active then
		return
	end

	active.view:show(file, {
		hunk = opts.hunk,
		on_done = function()
			if not active then
				return
			end
			if active.view.bufnr then
				attach_keymaps(active.view.bufnr)
				remember_mapped(active.view.bufnr)
			end
			repaint_panel()
			sync_panel_cursor()
			if opts.focus ~= false then
				focus_view()
			end
		end,
	})
end

---@param entry draven.OrderEntry
local function goto_entry(entry)
	if not active then
		return
	end

	if active.view.file and active.view.file.path == entry.file.path then
		active.view:goto_line(hunk_line(entry.hunk))
		repaint_panel()
		sync_panel_cursor()
		focus_view()
	else
		show_file(entry.file, { hunk = entry.hunk })
	end
end

---The file the cursor is over: the panel entry when in the panel, otherwise
---whatever the diff window is showing.
---@return draven.File|nil
local function current_file()
	if not active then
		return nil
	end

	if vim.api.nvim_get_current_win() == active.panel_win then
		local lnum = vim.api.nvim_win_get_cursor(active.panel_win)[1]
		local entry = active.panel:entry_at(lnum)
		if entry and entry.kind == "file" then
			return entry.file
		end
		return nil
	end

	return active.view.file
end

--- Actions -------------------------------------------------------------------

---@param backwards? boolean
function M.goto_next_unread(backwards)
	if not active then
		return
	end

	local from
	if active.view.file and vim.api.nvim_get_current_win() == active.view_win then
		local hunk = active.view:hunk_at_cursor()
		if hunk then
			from = active.session:position_of(hunk)
		end
	end

	local entry = active.session:next_unread(from, backwards)
	if not entry then
		log.info("nothing left to read")
		return
	end

	goto_entry(entry)
end

---@param reviewed boolean
function M.mark_hunk(reviewed)
	if not active then
		return
	end

	-- From the panel, marking applies to the whole file under the cursor.
	if vim.api.nvim_get_current_win() == active.panel_win then
		return M.mark_file(reviewed)
	end

	local hunk = active.view:hunk_at_cursor()
	if not hunk then
		log.info("no hunk here")
		return
	end

	active.session:mark(hunk, reviewed)
	active.view:redraw()
	repaint_panel()

	if reviewed then
		M.goto_next_unread(false)
	end
end

---@param reviewed boolean
function M.mark_file(reviewed)
	if not active then
		return
	end

	local file = current_file()
	if not file then
		log.info("no file here")
		return
	end

	active.session:mark_file(file, reviewed)
	active.view:redraw()
	repaint_panel()

	if reviewed then
		M.goto_next_unread(false)
	end
end

---@param reviewed boolean
function M.mark_all(reviewed)
	if not active then
		return
	end

	active.session:mark_all(reviewed)
	active.view:redraw()
	repaint_panel()

	local done, total = active.session:progress()
	log.info(("%d/%d hunks marked"):format(done, total))
end

---@param backwards? boolean
function M.goto_file(backwards)
	if not active then
		return
	end

	local files = active.session.changeset.files
	if #files == 0 then
		return
	end

	local index = 1
	if active.view.file then
		for i, f in ipairs(files) do
			if f.path == active.view.file.path then
				index = i
				break
			end
		end
	end

	local step = backwards and -1 or 1
	local next_index = ((index - 1 + step) % #files + #files) % #files + 1

	show_file(files[next_index])
end

function M.toggle_fold()
	if not active or not vim.api.nvim_win_is_valid(active.view_win) then
		return
	end
	vim.wo[active.view_win].foldenable = not vim.wo[active.view_win].foldenable
end

function M.open_entry()
	if not active then
		return
	end

	local win = vim.api.nvim_get_current_win()
	if win ~= active.panel_win then
		return
	end

	local lnum = vim.api.nvim_win_get_cursor(active.panel_win)[1]
	local entry = active.panel:entry_at(lnum)
	if not entry then
		return
	end

	if entry.kind == "dir" then
		active.panel:toggle_dir(entry.dir)
		repaint_panel()
		pcall(vim.api.nvim_win_set_cursor, active.panel_win, { lnum, 0 })
	elseif entry.kind == "file" then
		show_file(entry.file)
	end
end

function M.focus_panel()
	if active and vim.api.nvim_win_is_valid(active.panel_win) then
		vim.api.nvim_set_current_win(active.panel_win)
	end
end

---Rebuild the changeset from git, keeping every mark.
---@param opts? { silent?: boolean }
function M.refresh(opts)
	opts = opts or {}
	if not active then
		return
	end

	local rev = active.rev
	local cwd = active.session.changeset.root

	require("draven").changeset({ rev = rev, cwd = cwd }, function(err, cs)
		if not active then
			return
		end
		if err or not cs then
			log.error(err or "refresh failed")
			return
		end

		local path = active.view.file and active.view.file.path
		active.session:update(cs)
		repaint_panel()

		local file = path and changeset_mod.file(cs, path)
		if file then
			active.view.file = file
			active.view:redraw()
			-- Hunks may have moved, so the fold geometry is no longer valid.
			active.view:recompute_folds()
		else
			local entry = active.session:first_target()
			if entry then
				goto_entry(entry)
			end
		end

		if not opts.silent then
			local done, total = active.session:progress()
			log.info(("refreshed · %d/%d hunks read"):format(done, total))
		end
	end)
end

--- Lifecycle -----------------------------------------------------------------

---@return boolean
function M.is_open()
	return active ~= nil and vim.api.nvim_tabpage_is_valid(active.tabpage)
end

---Release everything a review owns: state flushed, decorations gone, mappings
---off your buffers, scratch buffers deleted.
---@param review draven.Review
local function teardown(review)
	review.session:close()
	review.view:close()

	for _, bufnr in ipairs(review.mapped) do
		detach_keymaps(bufnr)
		render.clear(bufnr)
	end

	if vim.api.nvim_buf_is_valid(review.panel.bufnr) then
		pcall(vim.api.nvim_buf_delete, review.panel.bufnr, { force = true })
	end

	pcall(vim.api.nvim_del_augroup_by_name, "draven.review")
end

function M.close()
	if not active then
		return
	end

	local review = active
	active = nil

	teardown(review)

	if vim.api.nvim_tabpage_is_valid(review.tabpage) and #vim.api.nvim_list_tabpages() > 1 then
		pcall(vim.api.nvim_win_close, review.panel_win, true)
		if vim.api.nvim_tabpage_is_valid(review.tabpage) then
			vim.api.nvim_set_current_tabpage(review.tabpage)
			pcall(vim.cmd, "tabclose")
		end
	end
end

---@param session draven.Session
---@return draven.Review
local function build_layout(session)
	local ui = config.options.ui

	vim.cmd("tabnew")
	local tabpage = vim.api.nvim_get_current_tabpage()
	local view_win = vim.api.nvim_get_current_win()

	-- The placeholder buffer `tabnew` made should not linger.
	vim.bo[vim.api.nvim_win_get_buf(view_win)].bufhidden = "wipe"

	local panel = panel_mod.new()

	vim.cmd(ui.panel.position == "right" and "botright vsplit" or "topleft vsplit")
	local panel_win = vim.api.nvim_get_current_win()

	vim.api.nvim_win_set_buf(panel_win, panel.bufnr)
	vim.api.nvim_win_set_width(panel_win, ui.panel.width)

	vim.wo[panel_win].winfixwidth = true
	vim.wo[panel_win].number = false
	vim.wo[panel_win].relativenumber = false
	vim.wo[panel_win].signcolumn = "no"
	vim.wo[panel_win].cursorline = true
	vim.wo[panel_win].wrap = false
	vim.wo[panel_win].foldenable = false
	vim.wo[panel_win].list = false
	vim.wo[panel_win].spell = false

	return {
		tabpage = tabpage,
		panel_win = panel_win,
		view_win = view_win,
		panel = panel,
		view = view_mod.new(view_win, session),
		session = session,
		mapped = {},
	}
end

local function install_autocmds()
	local group = vim.api.nvim_create_augroup("draven.review", { clear = true })

	vim.api.nvim_create_autocmd("TabClosed", {
		group = group,
		desc = "Tear down draven when its tab goes away",
		callback = function()
			if active and not vim.api.nvim_tabpage_is_valid(active.tabpage) then
				local review = active
				active = nil
				teardown(review)
			end
		end,
	})

	vim.api.nvim_create_autocmd("BufWritePost", {
		group = group,
		desc = "Refresh the review when a file in it is written",
		callback = function(args)
			if not active then
				return
			end
			local root = active.session.changeset.root
			local name = vim.api.nvim_buf_get_name(args.buf)
			if name:sub(1, #root) == root then
				vim.schedule(function()
					M.refresh({ silent = true })
				end)
			end
		end,
	})
end

---Open a review, or focus the one already open.
---@param opts? { rev?: string, cwd?: string }
function M.open(opts)
	opts = opts or {}

	if M.is_open() then
		vim.api.nvim_set_current_tabpage(active.tabpage)
		return
	end

	highlights.attach()

	require("draven").changeset({ rev = opts.rev, cwd = opts.cwd }, function(err, cs)
		if err or not cs then
			log.error(err or "could not build the changeset")
			return
		end

		if #cs.files == 0 then
			log.info("no changes to review")
			return
		end

		local session = session_mod.new(cs)

		active = build_layout(session)
		active.rev = opts.rev

		attach_keymaps(active.panel.bufnr, { panel = true })
		remember_mapped(active.panel.bufnr)

		install_autocmds()
		repaint_panel()

		local entry = session:first_target()
		if entry then
			show_file(entry.file, { hunk = entry.hunk })
		else
			show_file(cs.files[1])
		end
	end)
end

function M.toggle(opts)
	if M.is_open() then
		M.close()
	else
		M.open(opts)
	end
end

--- Action table --------------------------------------------------------------

actions = {
	mark_hunk = {
		desc = "[R]eview mark hunk [R]ead",
		fn = function()
			M.mark_hunk(true)
		end,
	},
	unmark_hunk = {
		desc = "[R]eview [U]nmark hunk",
		fn = function()
			M.mark_hunk(false)
		end,
	},
	mark_file = {
		desc = "[R]eview mark [F]ile read",
		fn = function()
			M.mark_file(true)
		end,
	},
	mark_all = {
		desc = "[R]eview mark [A]ll read",
		fn = function()
			M.mark_all(true)
		end,
	},
	next_hunk = {
		desc = "[R]eview [N]ext unread hunk",
		fn = function()
			M.goto_next_unread(false)
		end,
	},
	prev_hunk = {
		desc = "[R]eview [P]revious unread hunk",
		fn = function()
			M.goto_next_unread(true)
		end,
	},
	next_file = {
		desc = "Draven: next file",
		fn = function()
			M.goto_file(false)
		end,
	},
	prev_file = {
		desc = "Draven: previous file",
		fn = function()
			M.goto_file(true)
		end,
	},
	toggle_fold = {
		desc = "[R]eview toggle unchanged-code folds",
		fn = M.toggle_fold,
	},
	refresh = {
		desc = "[R]eview [R]efresh from git",
		fn = function()
			M.refresh()
		end,
	},
	focus_panel = {
		desc = "[R]eview focus panel",
		fn = M.focus_panel,
	},
	quit = {
		desc = "[R]eview [Q]uit",
		fn = M.close,
	},
	open_entry = {
		desc = "Draven: open entry",
		fn = M.open_entry,
	},
}

return M
