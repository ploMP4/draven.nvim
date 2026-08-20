---Unified diff parser.
---
---Pure: takes the text git printed, returns a table. No Neovim API beyond
---`vim.split`, so it is cheap to test and can move behind a native core later
---without touching anything above it.
local M = {}

---@class draven.DiffLine
---@field kind "context"|"add"|"delete"
---@field text string # without the leading marker
---@field old_lnum integer|nil
---@field new_lnum integer|nil
---@field no_newline boolean|nil

---@class draven.RawHunk
---@field old_start integer
---@field old_count integer
---@field new_start integer
---@field new_count integer
---@field section string # the text trailing the second `@@`
---@field lines draven.DiffLine[]

---@class draven.RawFile
---@field path string # post-image path (falls back to the old path on deletion)
---@field old_path string|nil
---@field status "added"|"modified"|"deleted"|"renamed"|"copied"|"mode"
---@field binary boolean
---@field old_mode string|nil
---@field new_mode string|nil
---@field similarity integer|nil
---@field hunks draven.RawHunk[]

local ESCAPES = {
	a = "\a",
	b = "\b",
	f = "\f",
	n = "\n",
	r = "\r",
	t = "\t",
	v = "\v",
	["\\"] = "\\",
	['"'] = '"',
}

---Undo git's C-style path quoting.
---@param s string
---@return string
local function unquote(s)
	if s:sub(1, 1) ~= '"' or s:sub(-1) ~= '"' then
		return s
	end
	local body = s:sub(2, -2)
	-- Octal first, so `\134` is not consumed by the single-character rule.
	body = body:gsub("\\(%d%d%d)", function(digits)
		return string.char(tonumber(digits, 8))
	end)
	body = body:gsub("\\(.)", function(c)
		return ESCAPES[c] or c
	end)
	return body
end

---@param p string
---@return string
local function strip_prefix(p)
	return (p:gsub("^[ab]/", ""))
end

---Recover both paths from a `diff --git` header. Only needed when the file has
---no `---`/`+++` lines, which happens for binary and mode-only changes.
---@param header string
---@return string|nil old_path
---@return string|nil new_path
local function paths_from_header(header)
	local rest = header:sub(12) -- after "diff --git "

	if rest:sub(1, 1) == '"' then
		local a, b = rest:match('^(".-[^\\]")%s+(.+)$')
		if a and b then
			return strip_prefix(unquote(a)), strip_prefix(unquote(b))
		end
	end

	-- Unquoted paths may contain spaces, so the split point is ambiguous. Git
	-- writes `a/<p> b/<p>` with the same `<p>` on both sides here (renames are
	-- reported through `rename from`/`rename to` instead), so look for the
	-- split that makes the two halves agree.
	local at = rest:find(" b/", 1, true)
	while at do
		local a, b = rest:sub(1, at - 1), rest:sub(at + 1)
		if a:sub(1, 2) == "a/" and a:sub(3) == b:sub(3) then
			return a:sub(3), b:sub(3)
		end
		at = rest:find(" b/", at + 1, true)
	end

	return nil, nil
end

---@param text string|nil
---@return draven.RawFile[]
function M.parse(text)
	---@type draven.RawFile[]
	local files = {}
	local file, hunk = nil, nil
	local old_lnum, new_lnum = 0, 0

	local function push(kind, body)
		local entry = { kind = kind, text = body }

		if kind == "context" then
			entry.old_lnum, entry.new_lnum = old_lnum, new_lnum
			old_lnum, new_lnum = old_lnum + 1, new_lnum + 1
			hunk._old_left, hunk._new_left = hunk._old_left - 1, hunk._new_left - 1
		elseif kind == "add" then
			entry.new_lnum = new_lnum
			new_lnum = new_lnum + 1
			hunk._new_left = hunk._new_left - 1
		else
			entry.old_lnum = old_lnum
			old_lnum = old_lnum + 1
			hunk._old_left = hunk._old_left - 1
		end

		hunk.lines[#hunk.lines + 1] = entry
	end

	for _, line in ipairs(vim.split(text or "", "\n", { plain = true })) do
		local consumed = false

		if hunk then
			local marker = line:sub(1, 1)

			if marker == "\\" then
				-- "\ No newline at end of file" annotates the line above it,
				-- and git emits it after a hunk's final line too — so this is
				-- checked before `_done`, which that line has already set.
				local prev = hunk.lines[#hunk.lines]
				if prev then
					prev.no_newline = true
				end
				consumed = true
			elseif hunk._done then
				hunk = nil
			elseif marker == " " then
				push("context", line:sub(2))
				consumed = true
			elseif marker == "+" then
				push("add", line:sub(2))
				consumed = true
			elseif marker == "-" then
				push("delete", line:sub(2))
				consumed = true
			elseif line == "" then
				-- Defensive: some pipelines strip the trailing space from an
				-- empty context line.
				push("context", "")
				consumed = true
			else
				hunk = nil
			end

			-- Counts, not blank lines, decide where a hunk ends. It stays
			-- addressable for one more line so a trailing `\` can land.
			if hunk and hunk._old_left <= 0 and hunk._new_left <= 0 then
				hunk._done = true
			end
		end

		if not consumed then
			if line:sub(1, 11) == "diff --git " then
				file = {
					status = "modified",
					binary = false,
					hunks = {},
					_header = line,
				}
				files[#files + 1] = file
			elseif file then
				if line:sub(1, 3) == "@@ " then
					local os_, oc, ns, nc, section =
						line:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@ ?(.*)$")

					if os_ then
						local old_count = oc == "" and 1 or tonumber(oc)
						local new_count = nc == "" and 1 or tonumber(nc)

						hunk = {
							old_start = tonumber(os_),
							old_count = old_count,
							new_start = tonumber(ns),
							new_count = new_count,
							section = section or "",
							lines = {},
							_old_left = old_count,
							_new_left = new_count,
						}

						old_lnum, new_lnum = hunk.old_start, hunk.new_start
						file.hunks[#file.hunks + 1] = hunk

						-- A header claiming no lines at all is already complete.
						if hunk._old_left <= 0 and hunk._new_left <= 0 then
							hunk._done = true
						end
					end
				elseif line:sub(1, 4) == "--- " then
					local p = line:sub(5)
					if p ~= "/dev/null" then
						file.old_path = strip_prefix(unquote(p))
					end
				elseif line:sub(1, 4) == "+++ " then
					local p = line:sub(5)
					if p ~= "/dev/null" then
						file.path = strip_prefix(unquote(p))
					end
				elseif line:sub(1, 14) == "new file mode " then
					file.status = "added"
					file.new_mode = line:sub(15)
				elseif line:sub(1, 18) == "deleted file mode " then
					file.status = "deleted"
					file.old_mode = line:sub(19)
				elseif line:sub(1, 9) == "old mode " then
					file.old_mode = line:sub(10)
				elseif line:sub(1, 9) == "new mode " then
					file.new_mode = line:sub(10)
				elseif line:sub(1, 12) == "rename from " then
					file.old_path = unquote(line:sub(13))
					file.status = "renamed"
				elseif line:sub(1, 10) == "rename to " then
					file.path = unquote(line:sub(11))
					file.status = "renamed"
				elseif line:sub(1, 10) == "copy from " then
					file.old_path = unquote(line:sub(11))
					file.status = "copied"
				elseif line:sub(1, 8) == "copy to " then
					file.path = unquote(line:sub(9))
					file.status = "copied"
				elseif line:sub(1, 17) == "similarity index " then
					file.similarity = tonumber(line:match("(%d+)%%"))
				elseif
					line:sub(1, 13) == "Binary files " or line:sub(1, 16) == "GIT binary patch"
				then
					file.binary = true
				end
			end
		end
	end

	for _, f in ipairs(files) do
		if not f.path or not f.old_path then
			local old_path, new_path = paths_from_header(f._header)
			f.old_path = f.old_path or (f.status ~= "added" and old_path or nil)
			f.path = f.path or new_path or f.old_path
		end

		-- Deletions have no post-image path; carry the old one so every file in
		-- a changeset can be addressed the same way.
		if f.status == "deleted" and not f.path then
			f.path = f.old_path
		end

		-- A rename that changed nothing still reports both paths; only call it
		-- a mode change when there is genuinely nothing else going on.
		if #f.hunks == 0 and not f.binary and f.status == "modified" then
			if f.old_mode and f.new_mode and f.old_mode ~= f.new_mode then
				f.status = "mode"
			end
		end

		if f.old_path == f.path then
			f.old_path = nil
		end

		f._header = nil
		for _, h in ipairs(f.hunks) do
			h._old_left, h._new_left, h._done = nil, nil, nil
		end
	end

	return files
end

return M
