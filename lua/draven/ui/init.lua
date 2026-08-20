---The review tabpage: panel, diff window, keymaps and the actions they call.
local config = require("draven.config")
local changeset_mod = require("draven.core.changeset")
local finding_mod = require("draven.finding")
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

---Defined below; forward-declared so the actions above can reach it.
local apply_panel_window_options

--- Keymaps -------------------------------------------------------------------

---@class draven.Action
---@field desc string
---@field fn fun()

---@type table<string, draven.Action>
local actions = {}

---Actions that only make sense in the panel. `<CR>` in particular must never
---be mapped into a real file buffer.
local PANEL_ONLY = {
	open_entry = true,
	collapse_dir = true,
	expand_dir = true,
	toggle_dir = true,
	collapse_all = true,
	expand_all = true,
}

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

--- Findings ------------------------------------------------------------------

---The finding under the cursor, preferring an unresolved one.
---@return draven.Finding|nil
local function finding_at_cursor()
	if not active then
		return nil
	end

	local win = vim.api.nvim_get_current_win()
	if win == active.panel_win then
		local lnum = vim.api.nvim_win_get_cursor(active.panel_win)[1]
		local entry = active.panel:entry_at(lnum)
		return entry and entry.kind == "finding" and entry.finding or nil
	end

	if win ~= active.view_win or not active.view.file or not active.view.bufnr then
		return nil
	end

	local lnum = vim.api.nvim_win_get_cursor(active.view_win)[1]
	local total = vim.api.nvim_buf_line_count(active.view.bufnr)
	local items = {}
	for _, item in ipairs(active.session:findings({ path = active.view.file.path })) do
		if finding_mod.display_lnum(item, total) == lnum then
			items[#items + 1] = item
		end
	end

	for _, item in ipairs(items) do
		if not item.resolved then
			return item
		end
	end

	return items[1]
end

---@param existing draven.Finding
local function edit_finding(existing)
	local comment = require("draven.ui.comment")
	comment.open({
		title = ("%s:%d%s"):format(
			existing.path,
			existing.lnum or existing.last_lnum or 0,
			existing.state == "orphaned" and " · orphaned" or ""
		),
		body = existing.body,
		severity = existing.severity,
		on_submit = function(body, severity)
			if not active then
				return
			end
			active.session:update_finding(existing.id, body, severity)
			active.view:redraw()
			repaint_panel()
		end,
	})
end

---Write a finding against the line under the cursor, or edit the one there.
function M.comment()
	if not active then
		return
	end

	local existing = finding_at_cursor()
	if existing then
		edit_finding(existing)
		return
	end

	if vim.api.nvim_get_current_win() ~= active.view_win then
		focus_view()
	end

	local file = active.view.file
	if not file then
		return
	end

	local comment = require("draven.ui.comment")

	local lnum = vim.api.nvim_win_get_cursor(active.view_win)[1]
	local hunk = active.session:hunk_at(file, lnum)

	if not hunk then
		log.info("findings attach to changed lines — move to a hunk first")
		return
	end

	comment.open({
		title = ("%s:%d"):format(file.path, lnum),
		on_submit = function(body, severity)
			if not active then
				return
			end
			active.session:add_finding(hunk, lnum, { body = body, severity = severity })
			active.view:redraw()
			repaint_panel()
		end,
	})
end

---Collapse the finding under the cursor, or open it back up.
function M.toggle_finding()
	local item = finding_at_cursor()
	if not item or not active then
		log.info("no finding here")
		return
	end

	local collapsed = active.session:toggle_collapsed(item.id)
	active.view:redraw()
	log.info(collapsed and "finding collapsed" or "finding expanded")
end

function M.toggle_resolved()
	local item = finding_at_cursor()
	if not item or not active then
		log.info("no finding here")
		return
	end

	local resolved = active.session:toggle_resolved(item.id)
	active.view:redraw()
	repaint_panel()
	log.info(resolved and "finding resolved" or "finding reopened")
end

function M.delete_finding()
	local item = finding_at_cursor()
	if not item or not active then
		log.info("no finding here")
		return
	end

	active.session:remove_finding(item.id)
	active.view:redraw()
	repaint_panel()
	log.info("finding deleted")
end

---Load findings into the quickfix list.
function M.list_findings()
	if not active then
		return
	end

	local count = require("draven.export").quickfix(active.session, { unresolved_only = false })
	if count == 0 then
		log.info("no findings yet")
	end
end

---Put the review on the clipboard as a prompt for the agent.
function M.export()
	if not active then
		return
	end

	local export = require("draven.export")
	local text, count = export.prompt(active.session, {
		unresolved_only = config.options.export.unresolved_only,
	})

	if count == 0 then
		log.info("no findings to export")
		return
	end

	if export.to_clipboard(text) then
		log.info(
			("%d finding%s copied to register %s"):format(
				count,
				count == 1 and "" or "s",
				config.options.export.register
			)
		)
	else
		log.error("could not write to register " .. config.options.export.register)
	end
end

---Show the delta between the approved version and what is there now.
function M.show_delta()
	if not active then
		return
	end

	local hunk = active.view:hunk_at_cursor()
	if not hunk then
		log.info("no hunk here")
		return
	end

	require("draven.ui.delta").open(active.session, hunk)
end

---Jump to the next hunk the agent rewrote under you.
---@param backwards? boolean
function M.goto_next_stale(backwards)
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

	local entry = active.session:next_stale(from, backwards)
	if not entry then
		log.info("nothing has changed since you read it")
		return
	end

	goto_entry(entry)
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
	elseif entry.kind == "finding" then
		edit_finding(entry.finding)
	end
end

function M.focus_panel()
	if active and vim.api.nvim_win_is_valid(active.panel_win) then
		vim.api.nvim_set_current_win(active.panel_win)
	end
end

---Collapse or expand the directory under the cursor. Panel only.
---@param collapsed boolean|nil # nil toggles
function M.fold_dir(collapsed)
	if not active or vim.api.nvim_get_current_win() ~= active.panel_win then
		return
	end

	local lnum = vim.api.nvim_win_get_cursor(active.panel_win)[1]
	local dir = active.panel:dir_at(lnum)
	if not dir then
		return
	end

	-- Expanding an already-open directory should not be a no-op keypress, so
	-- `l` on an open one opens the file instead.
	if collapsed == false and not active.panel.collapsed[dir] then
		return M.open_entry()
	end

	active.panel:toggle_dir(dir, collapsed)
	repaint_panel()

	local target = active.panel:line_of_dir(dir) or lnum
	pcall(vim.api.nvim_win_set_cursor, active.panel_win, { target, 0 })
end

---@param collapsed boolean
function M.fold_all(collapsed)
	if not active then
		return
	end

	active.panel:set_all(active.session, collapsed)
	repaint_panel()
	sync_panel_cursor()
end

---Hide the panel, or bring it back. The changeset tree is worth the width
---while you are picking what to read, and not while you are reading.
function M.toggle_panel()
	if not active then
		return
	end

	if vim.api.nvim_win_is_valid(active.panel_win) then
		active.panel_width = vim.api.nvim_win_get_width(active.panel_win)
		vim.api.nvim_win_close(active.panel_win, true)
		active.panel_win = -1
		focus_view()
		return
	end

	local ui = config.options.ui
	vim.api.nvim_set_current_win(active.view_win)
	vim.cmd(ui.panel.position == "right" and "botright vsplit" or "topleft vsplit")

	active.panel_win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(active.panel_win, active.panel.bufnr)
	vim.api.nvim_win_set_width(active.panel_win, active.panel_width or ui.panel.width)
	apply_panel_window_options(active.panel_win)

	repaint_panel()
	sync_panel_cursor()
	focus_view()
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
	require("draven.ui.delta").close()
	require("draven.ui.comment").close()

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

---@param win integer
function apply_panel_window_options(win)
	vim.wo[win].winfixwidth = true
	vim.wo[win].number = false
	vim.wo[win].relativenumber = false
	vim.wo[win].signcolumn = "no"
	vim.wo[win].cursorline = true
	vim.wo[win].wrap = false
	vim.wo[win].foldenable = false
	vim.wo[win].list = false
	vim.wo[win].spell = false
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
	apply_panel_window_options(panel_win)

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

		local session = session_mod.new(cs)
		if #cs.files == 0 and #session:findings() == 0 then
			log.info("no changes to review")
			return
		end

		active = build_layout(session)
		active.rev = opts.rev

		attach_keymaps(active.panel.bufnr, { panel = true })
		remember_mapped(active.panel.bufnr)

		install_autocmds()
		repaint_panel()

		local entry = session:first_target()
		if entry then
			show_file(entry.file, { hunk = entry.hunk })
		elseif cs.files[1] then
			show_file(cs.files[1])
		else
			M.focus_panel()
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
	delta = {
		desc = "[R]eview [D]elta — what changed since you read it",
		fn = M.show_delta,
	},
	comment = {
		desc = "[R]eview [C]omment on this line",
		fn = M.comment,
	},
	list_findings = {
		desc = "[R]eview [L]ist findings in the quickfix list",
		fn = M.list_findings,
	},
	export = {
		desc = "[R]eview e[X]port findings as an agent prompt",
		fn = M.export,
	},
	toggle_resolved = {
		desc = "[R]eview [T]oggle finding resolved",
		fn = M.toggle_resolved,
	},
	toggle_finding = {
		desc = "[R]eview [V]iew finding body",
		fn = M.toggle_finding,
	},
	delete_finding = {
		desc = "[R]eview delete finding",
		fn = M.delete_finding,
	},
	next_stale = {
		desc = "[R]eview next [S]tale hunk",
		fn = function()
			M.goto_next_stale(false)
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
	toggle_panel = {
		desc = "[R]eview toggle the changeset panel",
		fn = M.toggle_panel,
	},
	collapse_dir = {
		desc = "Draven: collapse this directory",
		fn = function()
			M.fold_dir(true)
		end,
	},
	expand_dir = {
		desc = "Draven: expand this directory",
		fn = function()
			M.fold_dir(false)
		end,
	},
	toggle_dir = {
		desc = "Draven: fold this directory",
		fn = function()
			M.fold_dir(nil)
		end,
	},
	collapse_all = {
		desc = "Draven: collapse every directory",
		fn = function()
			M.fold_all(true)
		end,
	},
	expand_all = {
		desc = "Draven: expand every directory",
		fn = function()
			M.fold_all(false)
		end,
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
