local this = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(this, ":p:h:h")

local function find_plenary()
	local candidates = {
		root .. "/.tests/plenary.nvim",
		vim.fn.stdpath("data") .. "/lazy/plenary.nvim",
		vim.fn.stdpath("data") .. "/site/pack/vendor/start/plenary.nvim",
	}

	for _, path in ipairs(candidates) do
		if vim.fn.isdirectory(path) == 1 then
			return path
		end
	end

	for _, path in ipairs(vim.fn.glob(vim.fn.stdpath("data") .. "/site/pack/*/start/plenary.nvim", true, true)) do
		if vim.fn.isdirectory(path) == 1 then
			return path
		end
	end

	return nil
end

local plenary = find_plenary()
if not plenary then
	io.stderr:write("plenary.nvim not found — run `make deps`\n")
	vim.cmd("cquit 1")
end

vim.opt.rtp = { vim.env.VIMRUNTIME }
vim.opt.rtp:append(plenary)
vim.opt.rtp:append(root)

-- So specs can `require("helpers")`.
package.path = root .. "/tests/?.lua;" .. package.path

vim.opt.swapfile = false
vim.env.GIT_CONFIG_GLOBAL = "/dev/null"
vim.env.GIT_CONFIG_SYSTEM = "/dev/null"

vim.cmd("runtime plugin/plenary.vim")
require("plenary.busted")
