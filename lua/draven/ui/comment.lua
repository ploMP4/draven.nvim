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

---@param win integer
---@param severity draven.Severity
---@param editing boolean
local function set_footer(win, severity, editing)
	if not vim.api.nvim_win_is_valid(win) then
		return
	end

	local hl = ({
		blocking = "DravenFindingBlocking",
		question = "DravenFindingQuestion",
		nit = "DravenFindingNit",
	})[severity] or "DravenFindingBlocking"

	vim.api.nvim_win_set_config(win, {
		footer = {
			{ " " .. severity .. " ", hl },
			{ "<Tab> severity  <C-s> " .. (editing and "save" or "add") .. "  <Esc> cancel ", "Comment" },
		},
		footer_pos = "right",
	})
end

---Open the composer.
---@param opts { title: string, body?: string, severity?: draven.Severity, on_submit: fun(body: string, severity: draven.Severity) }
function M.open(opts)
	M.close()

	local ui = config.options.ui.comment
	local severity = finding_mod.normalize_severity(opts.severity or config.options.findings.default_severity)
	local editing = opts.body ~= nil and opts.body ~= ""

	local bufnr = vim.api.nvim_create_buf(false, true)
	vim.bo[bufnr].buftype = "acwrite"
	vim.bo[bufnr].bufhidden = "wipe"
	vim.bo[bufnr].filetype = "markdown"
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.split(opts.body or "", "\n", { plain = true }))
	pcall(vim.api.nvim_buf_set_name, bufnr, "draven://finding")

	local width = math.min(ui.width, math.max(40, vim.o.columns - 8))
	local height = math.min(ui.height, math.max(3, vim.o.lines - 6))

	open_win = vim.api.nvim_open_win(bufnr, true, {
		relative = "editor",
		width = width,
		height = height,
		row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
		col = math.max(0, math.floor((vim.o.columns - width) / 2)),
		style = "minimal",
		border = ui.border,
		title = " " .. opts.title .. " ",
		title_pos = "center",
	})

	vim.wo[open_win].wrap = true
	vim.wo[open_win].linebreak = true
	vim.wo[open_win].number = false
	vim.wo[open_win].relativenumber = false
	vim.wo[open_win].signcolumn = "no"
	vim.wo[open_win].winblend = config.options.ui.winblend
	vim.wo[open_win].winhighlight = table.concat({
		"Normal:DravenFloat",
		"NormalFloat:DravenFloat",
		"FloatBorder:DravenFloatBorder",
		"FloatTitle:DravenFloatTitle",
		"FloatFooter:DravenFloatFooter",
		"EndOfBuffer:DravenFloat",
	}, ",")
	set_footer(open_win, severity, editing)

	local submitted = false

	local function submit()
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
		set_footer(open_win, severity, editing)
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
