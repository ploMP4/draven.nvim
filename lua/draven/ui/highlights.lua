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

	-- Sign column
	DravenSignReviewed = "DiagnosticOk",
	DravenSignUnread = "DiagnosticHint",
	DravenSignStale = "DiagnosticWarn",
	DravenSignBar = "Comment",
	DravenHunkAdd = "DiffAdd",
	DravenHunkContext = "Comment",
	DravenSignAdd = "DiffAdd",
	DravenSignDelete = "DiffDelete",

	-- Inline diff markers, in the first cells of the text area
	DravenMarkerAdd = "DiffAdd",
	DravenMarkerDelete = "DiffDelete",
	DravenMarkerContext = "Normal",

	-- Findings
	DravenFindingBlocking = "DiagnosticError",
	DravenFindingQuestion = "DiagnosticWarn",
	DravenFindingNit = "DiagnosticHint",
	DravenFindingResolved = "NonText",
	-- The mark on the commented line itself. Underlines rather than
	-- backgrounds, so the diff's own colours survive underneath.
	DravenFindingBlockingLine = "DiagnosticUnderlineError",
	DravenFindingQuestionLine = "DiagnosticUnderlineWarn",
	DravenFindingNitLine = "DiagnosticUnderlineHint",
	DravenFindingResolvedLine = "DiagnosticUnderlineOk",

	-- Floats. NormalFloat is the right thing to follow; a colorscheme that
	-- wants transparent floats says so there.
	DravenFloat = "NormalFloat",
	DravenFloatBorder = "FloatBorder",
	DravenFloatTitle = "FloatTitle",
	DravenFloatFooter = "FloatFooter",
	DravenCommentTitle = "FloatTitle",
	DravenCommentHint = "NonText",

	-- The v1→v2 delta
	DravenDeltaAdd = "DiffAdd",
	DravenDeltaDelete = "DiffDelete",
	DravenDeltaHeader = "Title",
	DravenDeltaMeta = "Comment",
	DravenDeltaHunk = "DiffChange",

	-- Panel
	DravenPanelTitle = "Title",
	DravenPanelBase = "Comment",
	DravenPanelProgress = "Special",
	DravenPanelDir = "Directory",
	DravenPanelFile = "Normal",
	DravenPanelCount = "Comment",
	DravenPanelReviewed = "DiagnosticOk",
	DravenPanelPartial = "DiagnosticInfo",
	DravenPanelStale = "DiagnosticWarn",
	DravenPanelUnread = "DiagnosticHint",
	DravenPanelIgnored = "NonText",
	DravenPanelActive = "CursorLine",
	DravenPanelHint = "NonText",
	DravenPanelGuide = "Comment",
	DravenPanelRule = "NonText",
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
