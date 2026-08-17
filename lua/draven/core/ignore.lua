---Ignore rules for generated and vendored files.
---
---Ignored files still appear in the changeset — you can always open one — but
---they do not count toward review progress.
local config = require("draven.config")
local glob = require("draven.util.glob")

local M = {}

---@type table<string, vim.regex|false>
local cache = {}
local cache_generation = -1

local function ensure_cache()
	if cache_generation ~= config.generation then
		cache = {}
		cache_generation = config.generation
	end
end

---@param pattern string
---@return vim.regex|false
local function compiled(pattern)
	local hit = cache[pattern]
	if hit == nil then
		hit = glob.compile(pattern) or false
		cache[pattern] = hit
	end
	return hit
end

---@param path string # repo-relative, forward slashes
---@return boolean
function M.match(path)
	local opts = config.options.ignore
	if not opts.enabled then
		return false
	end

	ensure_cache()

	for _, pattern in ipairs(opts.patterns) do
		local re = compiled(pattern)
		if re and re:match_str(path) then
			return true
		end
	end

	return false
end

---Drop compiled patterns. Called implicitly when config changes.
function M.clear_cache()
	cache = {}
	cache_generation = config.generation
end

return M
