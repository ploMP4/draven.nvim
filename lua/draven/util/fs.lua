---Awaitable filesystem reads.
---
---Untracked files have no blob in the object database, so their contents come
---off disk. These run through libuv so a large working tree never blocks the
---editor. Every continuation is scheduled back onto the main loop, so callers
---may use the full `vim.*` API after awaiting.
local async = require("draven.util.async")

local uv = vim.uv or vim.loop

local M = {}

---@param path string
---@return uv.fs_stat.result|nil stat
---@return string|nil err
function M.stat(path)
	return async.await(function(resume)
		uv.fs_stat(path, function(err, stat)
			vim.schedule(function()
				resume(stat, err)
			end)
		end)
	end)
end

---@param path string
---@return string|nil data
---@return string|nil err
function M.read(path)
	return async.await(function(resume)
		local function finish(data, err)
			vim.schedule(function()
				resume(data, err)
			end)
		end

		uv.fs_open(path, "r", 438, function(open_err, fd)
			if open_err or not fd then
				return finish(nil, open_err or "could not open file")
			end

			uv.fs_fstat(fd, function(stat_err, stat)
				if stat_err or not stat then
					uv.fs_close(fd, function() end)
					return finish(nil, stat_err or "could not stat file")
				end

				if stat.size == 0 then
					uv.fs_close(fd, function() end)
					return finish("", nil)
				end

				uv.fs_read(fd, stat.size, 0, function(read_err, data)
					uv.fs_close(fd, function() end)
					finish(data, read_err)
				end)
			end)
		end)
	end)
end

---Heuristic used by git itself: a NUL byte near the start means binary.
---@param data string
---@return boolean
function M.looks_binary(data)
	return data:sub(1, 8000):find("\0", 1, true) ~= nil
end

return M
