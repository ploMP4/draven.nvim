---Leveled notifications, filtered by `config.options.log_level`.
local config = require("draven.config")

local M = {}

---@param msg string
---@param level integer
local function notify(msg, level)
	if level < config.options.log_level then
		return
	end
	vim.schedule(function()
		vim.notify("[draven] " .. msg, level)
	end)
end

function M.debug(msg)
	notify(msg, vim.log.levels.DEBUG)
end

function M.info(msg)
	notify(msg, vim.log.levels.INFO)
end

function M.warn(msg)
	notify(msg, vim.log.levels.WARN)
end

function M.error(msg)
	notify(msg, vim.log.levels.ERROR)
end

return M
