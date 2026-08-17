---Highlight groups.
---
---Everything links to a group the colorscheme already defines, so draven looks
---like the rest of your editor without knowing anything about it. All links are
---`default`, so your own `:highlight` calls win.
local M = {}

local LINKS = {
	-- Diff body
	DravenAdd = "DiffAdd",
	DravenDelete = "DiffDelete",
	DravenChange = "DiffChange",
	DravenDeleteText = "DiffDelete",

	-- Sign column
	DravenSignReviewed = "DiagnosticOk",
	DravenSignUnread = "DiagnosticHint",
	DravenSignBar = "Comment",

	-- Panel
	DravenPanelTitle = "Title",
	DravenPanelBase = "Comment",
	DravenPanelProgress = "Special",
	DravenPanelDir = "Directory",
	DravenPanelFile = "Normal",
	DravenPanelCount = "Comment",
	DravenPanelReviewed = "DiagnosticOk",
	DravenPanelPartial = "DiagnosticWarn",
	DravenPanelUnread = "DiagnosticHint",
	DravenPanelIgnored = "NonText",
	DravenPanelActive = "CursorLine",
	DravenPanelStatus = "Comment",
	DravenPanelHint = "NonText",

	-- Scratch buffers standing in for content that is not on disk
	DravenNotice = "Comment",
}

function M.setup()
	for group, target in pairs(LINKS) do
		vim.api.nvim_set_hl(0, group, { link = target, default = true })
	end
end

---Re-link after a colorscheme change. `default = true` links survive a
---colorscheme swap only if the target still exists, so just redefine them.
function M.attach()
	M.setup()

	vim.api.nvim_create_autocmd("ColorScheme", {
		group = vim.api.nvim_create_augroup("draven.highlights", { clear = true }),
		desc = "Re-apply draven highlight links",
		callback = M.setup,
	})
end

return M
