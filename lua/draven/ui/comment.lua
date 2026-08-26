---Composing a finding.
---
---A real scratch buffer in a float, so writing a review comment is just
---editing text: your insert mappings, your abbreviations, undo, everything.
---`<Tab>` cycles severity, `<C-s>` (or `:w`) saves, `<Esc>` in normal mode
---throws it away.
local config = require("draven.config")
local finding_mod = require("draven.finding")

local M = {}

---@type integer|nil
local open_win = nil

function M.close()
	if open_win and vim.api.nvim_win_is_valid(open_win) then
		vim.api.nvim_win_close(open_win, true)
	end
	open_win = nil
end

---@param text string
---@param width integer
---@return string
local function truncate_display(text, width)
	if width <= 0 then
		return ""
	end
	if vim.fn.strdisplaywidth(text) <= width then
		return text
	end

	local suffix = width > 1 and "…" or ""
	local limit = width - vim.fn.strdisplaywidth(suffix)
	local chars, used, take = vim.fn.strchars(text), 0, 0
	for index = 1, chars do
		local char = vim.fn.strcharpart(text, index - 1, 1)
		local char_width = vim.fn.strdisplaywidth(char)
		if used + char_width > limit then
			break
		end
		used = used + char_width
		take = index
	end

	return vim.fn.strcharpart(text, 0, take) .. suffix
end

---@param severity draven.Severity
---@return string icon
---@return string label
---@return string highlight
local function severity_style(severity)
	local style = ({
		blocking = { "●", "BLOCKING", "DravenFindingBlocking" },
		question = { "?", "QUESTION", "DravenFindingQuestion" },
		nit = { "◇", "NIT", "DravenFindingNit" },
	})[severity] or { "●", "BLOCKING", "DravenFindingBlocking" }
	return style[1], style[2], style[3]
end

---@param win integer
---@param title string
---@param severity draven.Severity
---@param editing boolean
---@param insert_mode? boolean
local function set_chrome(win, title, severity, editing, insert_mode)
	if not win or not vim.api.nvim_win_is_valid(win) then
		return
	end

	local icon, label, hl = severity_style(severity)
	local width = vim.api.nvim_win_get_width(win)
	local action = editing and "Edit comment" or "New comment"
	local title_width = math.max(4, width - vim.fn.strdisplaywidth(action) - 7)
	local location = truncate_display(title, title_width)
	local escape_action = insert_mode and "normal" or "close"

	local footer = { { " " .. icon .. " " .. label .. " ", hl } }
	if width >= 56 then
		vim.list_extend(footer, {
			{ "  Tab", "DravenCommentKey" },
			{ " type", "DravenCommentMeta" },
			{ "   Ctrl-S", "DravenCommentKey" },
			{ " save", "DravenCommentMeta" },
			{ "   Esc", "DravenCommentKey" },
			{ " " .. escape_action .. " ", "DravenCommentMeta" },
		})
	else
		vim.list_extend(footer, {
			{ "  ^S", "DravenCommentKey" },
			{ " save  ", "DravenCommentMeta" },
			{ "Esc", "DravenCommentKey" },
			{ " " .. escape_action .. " ", "DravenCommentMeta" },
		})
	end

	vim.api.nvim_win_set_config(win, {
		title = {
			{ " " .. action .. " ", "DravenCommentTitle" },
			{ "· " .. location .. " ", "DravenCommentLocation" },
		},
		title_pos = "left",
		footer = footer,
		footer_pos = "right",
	})
end

---@param width integer
---@param height integer
---@return table
local function placement(width, height)
	local origin = vim.api.nvim_get_current_win()
	if vim.api.nvim_win_is_valid(origin) and vim.api.nvim_win_get_config(origin).relative == "" then
		local win_height = vim.api.nvim_win_get_height(origin)
		local win_width = vim.api.nvim_win_get_width(origin)
		local screen_row = vim.api.nvim_win_call(origin, function()
			return vim.fn.winline()
		end)
		local col = math.max(0, math.min(2, win_width - width - 1))

		if win_height - screen_row >= height + 2 then
			return {
				relative = "win",
				win = origin,
				row = screen_row,
				col = col,
				anchor = "NW",
			}
		elseif screen_row >= height + 2 then
			return {
				relative = "win",
				win = origin,
				row = screen_row - 1,
				col = col,
				anchor = "SW",
			}
		end
	end

	return {
		relative = "editor",
		row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
		col = math.max(0, math.floor((vim.o.columns - width) / 2)),
	}
end

---Open the composer.
---@param opts { title: string, body?: string, severity?: draven.Severity, on_submit: fun(body: string, severity: draven.Severity) }
function M.open(opts)
	M.close()

	local ui = config.options.ui.comment
	local severity =
		finding_mod.normalize_severity(opts.severity or config.options.findings.default_severity)
	local editing = opts.body ~= nil and opts.body ~= ""

	local bufnr = vim.api.nvim_create_buf(false, true)
	vim.bo[bufnr].buftype = "acwrite"
	vim.bo[bufnr].bufhidden = "wipe"
	vim.bo[bufnr].filetype = "markdown"
	vim.api.nvim_buf_set_lines(
		bufnr,
		0,
		-1,
		false,
		vim.split(opts.body or "", "\n", { plain = true })
	)
	pcall(vim.api.nvim_buf_set_name, bufnr, "draven://finding")

	local origin = vim.api.nvim_get_current_win()
	local origin_width = vim.api.nvim_win_is_valid(origin) and vim.api.nvim_win_get_width(origin)
		or vim.o.columns
	local width = math.min(
		ui.width,
		math.max(40, math.min(vim.o.columns - 8, origin_width - 4))
	)
	local height = math.min(ui.height, math.max(3, vim.o.lines - 6))
	local window_config = vim.tbl_extend("force", placement(width, height), {
		width = width,
		height = height,
		style = "minimal",
		border = ui.border,
	})

	open_win = vim.api.nvim_open_win(bufnr, true, window_config)

	vim.wo[open_win].wrap = true
	vim.wo[open_win].linebreak = true
	vim.wo[open_win].breakindent = true
	vim.wo[open_win].number = false
	vim.wo[open_win].relativenumber = false
	vim.wo[open_win].cursorline = false
	vim.wo[open_win].spell = false
	vim.wo[open_win].signcolumn = "yes:1"
	vim.wo[open_win].fillchars = "eob: "
	vim.wo[open_win].winblend = config.options.ui.winblend
	vim.wo[open_win].winhighlight = table.concat({
		"Normal:DravenFloat",
		"NormalFloat:DravenFloat",
		"FloatBorder:DravenFloatBorder",
		"FloatTitle:DravenFloatTitle",
		"FloatFooter:DravenFloatFooter",
		"EndOfBuffer:DravenFloat",
	}, ",")
	set_chrome(open_win, opts.title, severity, editing, false)

	-- Placeholder, so an empty composer says what it wants.
	local ns = vim.api.nvim_create_namespace("draven.comment")
	local function refresh_placeholder()
		vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
		local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
		if #lines <= 1 and vim.trim(lines[1] or "") == "" then
			pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, 0, 0, {
				virt_text = {
					{ "Describe the issue and the change you expect…", "DravenCommentHint" },
				},
				virt_text_pos = "overlay",
			})
		end
	end
	refresh_placeholder()

	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
		buffer = bufnr,
		callback = refresh_placeholder,
	})

	vim.api.nvim_create_autocmd("ModeChanged", {
		buffer = bufnr,
		callback = function()
			local insert_mode = vim.api.nvim_get_mode().mode:sub(1, 1) == "i"
			set_chrome(open_win, opts.title, severity, editing, insert_mode)
		end,
	})

	local submitted = false

	local function submit()
		-- <C-s> is mapped in insert mode too, and the mode outlives the float:
		-- without this you land back on your own source file still inserting.
		vim.cmd("stopinsert")

		local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
		local body = vim.trim(table.concat(lines, "\n"))

		if body == "" then
			require("draven.util.log").info("nothing written — finding discarded")
			M.close()
			return
		end

		submitted = true
		vim.bo[bufnr].modified = false
		M.close()
		opts.on_submit(body, severity)
	end

	vim.keymap.set({ "n", "i" }, "<C-s>", submit, { buffer = bufnr, desc = "Save finding" })
	vim.keymap.set("n", "ZZ", submit, { buffer = bufnr, desc = "Save finding" })

	vim.keymap.set({ "n", "i" }, "<Tab>", function()
		severity = finding_mod.next_severity(severity)
		local insert_mode = vim.api.nvim_get_mode().mode:sub(1, 1) == "i"
		set_chrome(open_win, opts.title, severity, editing, insert_mode)
	end, { buffer = bufnr, desc = "Cycle severity" })

	vim.keymap.set("n", "<Esc>", function()
		M.close()
	end, { buffer = bufnr, desc = "Discard finding" })

	vim.keymap.set("n", "q", function()
		M.close()
	end, { buffer = bufnr, desc = "Discard finding" })

	-- `:w` should mean the same thing as <C-s>.
	vim.api.nvim_create_autocmd("BufWriteCmd", {
		buffer = bufnr,
		callback = submit,
	})

	vim.api.nvim_create_autocmd("BufWipeout", {
		buffer = bufnr,
		once = true,
		callback = function()
			if not submitted then
				open_win = nil
			end
		end,
	})

	if not editing then
		vim.cmd("startinsert")
	end
end

return M
