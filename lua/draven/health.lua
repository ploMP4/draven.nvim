---`:checkhealth draven`
local M = {}

function M.check()
	local health = vim.health
	health.start("draven")

	if vim.fn.has("nvim-0.10") == 1 then
		health.ok("Neovim " .. tostring(vim.version()))
	else
		health.error("Neovim 0.10 or newer is required")
	end

	local config = require("draven.config")
	local bin = config.options.git.bin

	if vim.fn.executable(bin) == 0 then
		health.error(("git executable '%s' not found"):format(bin))
		return
	end

	local version = vim.fn.system({ bin, "--version" }):match("(%d+%.%d+%.%d+)")
	if version then
		health.ok(("git %s"):format(version))
	else
		health.warn(("could not determine the version of '%s'"):format(bin))
	end

	vim.fn.system({ bin, "rev-parse", "--show-toplevel" })
	if vim.v.shell_error == 0 then
		health.ok("current directory is inside a git repository")
	else
		health.info("current directory is not a git repository — open one to review")
	end

	local ignore_count = #config.options.ignore.patterns
	if config.options.ignore.enabled then
		health.ok(("%d ignore pattern%s active"):format(ignore_count, ignore_count == 1 and "" or "s"))
	else
		health.info("ignore rules are disabled")
	end
end

return M
