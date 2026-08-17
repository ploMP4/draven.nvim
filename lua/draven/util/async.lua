---Minimal coroutine-based async runtime.
---
---An "async function" is any function that, when called inside a coroutine
---started by `run`, may suspend via `await`. `await` takes a *thunk*: a
---function that receives a continuation and eventually calls it with the
---results. This keeps `core/` readable as straight-line code while every git
---call stays off the main loop.
---
---Errors propagate as normal Lua errors and surface in `run`'s callback.
local M = {}

local unpack = table.unpack or unpack

---Suspend until `thunk` calls its continuation.
---@param thunk fun(resume: fun(...))
---@return ... # whatever `resume` was called with
function M.await(thunk)
	return coroutine.yield(thunk)
end

---Run `fn` as a coroutine to completion.
---@param fn fun(): ... # coroutine body
---@param on_done? fun(err: string|nil, ...) # receives the body's return values
function M.run(fn, on_done)
	local co = coroutine.create(fn)

	local function fail(err)
		if on_done then
			on_done(err)
		else
			vim.schedule(function()
				error(err, 0)
			end)
		end
	end

	local step
	step = function(...)
		local res = { coroutine.resume(co, ...) }

		if not res[1] then
			return fail(debug.traceback(co, tostring(res[2])))
		end

		if coroutine.status(co) == "dead" then
			if on_done then
				on_done(nil, unpack(res, 2))
			end
			return
		end

		local thunk = res[2]
		if type(thunk) ~= "function" then
			return fail(("draven: await expected a function, got %s"):format(type(thunk)))
		end

		-- `thunk` is invoked after resume returned, so the coroutine is already
		-- suspended; a synchronous continuation is safe. Guard against a thunk
		-- that calls back more than once.
		local resumed = false
		thunk(function(...)
			if resumed then
				return
			end
			resumed = true
			step(...)
		end)
	end

	step()
end

---Wrap a callback-style function so it can be `await`ed.
---The callback must be the last of `argc` arguments.
---@param fn function
---@param argc integer
---@return function
function M.wrap(fn, argc)
	return function(...)
		local args = { ... }
		return M.await(function(resume)
			args[argc] = resume
			fn(unpack(args, 1, argc))
		end)
	end
end

---Run several async functions concurrently and await all of them.
---@param fns (fun(): any)[]
---@return any[] # results, positionally matching `fns`
function M.all(fns)
	if #fns == 0 then
		return {}
	end
	return M.await(function(resume)
		local results, remaining, failed = {}, #fns, nil
		for i, fn in ipairs(fns) do
			M.run(fn, function(err, value)
				if err then
					failed = failed or err
				else
					results[i] = value
				end
				remaining = remaining - 1
				if remaining == 0 then
					if failed then
						-- Surface inside the awaiting coroutine.
						error(failed, 0)
					end
					resume(results)
				end
			end)
		end
	end)
end

---Run `fn` and block until it finishes. For scripting and tests only —
---never call this from a mapping or autocmd.
---@param fn fun(): ...
---@param timeout_ms? integer
---@return ...
function M.block(fn, timeout_ms)
	local done, err, results = false, nil, {}

	M.run(fn, function(e, ...)
		done, err, results = true, e, { ... }
	end)

	local ok = vim.wait(timeout_ms or 30000, function()
		return done
	end, 5)

	if not ok then
		error("draven: async operation timed out", 0)
	end
	if err then
		error(err, 0)
	end
	return unpack(results)
end

return M
