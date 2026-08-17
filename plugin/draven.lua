if vim.g.loaded_draven then
	return
end
vim.g.loaded_draven = true

if vim.fn.has("nvim-0.10") == 0 then
	vim.notify("[draven] requires Neovim 0.10 or newer", vim.log.levels.ERROR)
	return
end

---Complete revisions: local branches, tags, remotes, plus a few HEAD offsets.
---@param arglead string
---@return string[]
local function complete_rev(arglead)
	local candidates = { "HEAD", "HEAD~1", "HEAD~5", "main...HEAD", "master...HEAD" }

	local out = vim.fn.systemlist({
		"git",
		"for-each-ref",
		"--format=%(refname:short)",
		"refs/heads",
		"refs/tags",
		"refs/remotes",
	})

	if vim.v.shell_error == 0 then
		vim.list_extend(candidates, out)
	end

	return vim.tbl_filter(function(c)
		return c:sub(1, #arglead) == arglead
	end, candidates)
end

vim.api.nvim_create_user_command("Draven", function(cmd)
	require("draven").open({ rev = cmd.args })
end, {
	nargs = "?",
	complete = complete_rev,
	desc = "Review a changeset (no argument: working tree vs HEAD)",
})

vim.api.nvim_create_user_command("DravenClose", function()
	require("draven").close()
end, { desc = "Close the review and save its state" })

vim.api.nvim_create_user_command("DravenToggle", function(cmd)
	require("draven").toggle({ rev = cmd.args })
end, {
	nargs = "?",
	complete = complete_rev,
	desc = "Toggle the review surface",
})

vim.api.nvim_create_user_command("DravenExport", function()
	require("draven").export()
end, { desc = "Copy the review's findings as a prompt for your agent" })

vim.api.nvim_create_user_command("DravenFindings", function()
	require("draven").findings()
end, { desc = "Load the review's findings into the quickfix list" })

vim.api.nvim_create_user_command("DravenReset", function(cmd)
	require("draven").reset({ rev = cmd.args, force = cmd.bang })
end, {
	nargs = "?",
	bang = true,
	complete = complete_rev,
	desc = "Discard a review's marks and findings (! to skip the prompt)",
})

vim.api.nvim_create_user_command("DravenStatus", function(cmd)
	require("draven").status(cmd.args, { verbose = cmd.bang })
end, {
	nargs = "?",
	bang = true,
	complete = complete_rev,
	desc = "Report a changeset without opening it (! for a per-file breakdown)",
})
