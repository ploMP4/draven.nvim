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
	require("draven").review(cmd.args, { verbose = cmd.bang })
end, {
	nargs = "?",
	bang = true,
	complete = complete_rev,
	desc = "Review a changeset (no argument: working tree vs HEAD)",
})
