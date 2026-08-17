---Glob -> Vim regex conversion.
---
---Lua patterns cannot express an optional group, which `**/` needs (it must
---match zero or more leading directories). Vim's "very magic" regex can, so
---ignore rules compile down to `vim.regex` instead.
---
---Supported syntax:
---  `**/`  zero or more directories
---  `**`   anything, including `/`
---  `*`    anything except `/`
---  `?`    one character except `/`
local M = {}

---@param glob string
---@return string # a very-magic Vim pattern anchored at both ends
function M.to_vim_pattern(glob)
	local out = { [[\v^]] }
	local i, n = 1, #glob

	while i <= n do
		local c = glob:sub(i, i)

		if glob:sub(i, i + 2) == "**/" then
			out[#out + 1] = [[%(.*/)?]]
			i = i + 3
		elseif glob:sub(i, i + 1) == "**" then
			out[#out + 1] = ".*"
			i = i + 2
		elseif c == "*" then
			out[#out + 1] = "[^/]*"
			i = i + 1
		elseif c == "?" then
			out[#out + 1] = "[^/]"
			i = i + 1
		elseif c:match("[%w/]") or c == "_" then
			-- Passed through: `_` must never be escaped, `\_` is a Vim atom.
			out[#out + 1] = c
			i = i + 1
		else
			out[#out + 1] = "\\" .. c
			i = i + 1
		end
	end

	out[#out + 1] = "$"
	return table.concat(out)
end

---Compile a glob, returning nil if it is malformed.
---@param glob string
---@return vim.regex|nil
function M.compile(glob)
	local ok, re = pcall(vim.regex, M.to_vim_pattern(glob))
	if not ok then
		return nil
	end
	return re
end

---Convenience one-shot match. Prefer `compile` + cache in hot paths.
---@param glob string
---@param path string
---@return boolean
function M.match(glob, path)
	local re = M.compile(glob)
	return re ~= nil and re:match_str(path) ~= nil
end

return M
