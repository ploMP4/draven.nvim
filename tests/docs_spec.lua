---Documentation that drifts is worse than none, so the parts that can be
---checked mechanically are.
local config = require("draven.config")

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local help = root .. "/doc/draven.txt"

---@return string[]
local function help_lines()
	return vim.fn.readfile(help)
end

---@return string
local function help_text()
	return table.concat(help_lines(), "\n")
end

describe("help file", function()
	it("exists and declares itself", function()
		assert.equals(1, vim.fn.filereadable(help))
		assert.is_truthy(help_lines()[1]:match("^%*draven%.txt%*"))
	end)

	it("ends with a modeline", function()
		local lines = help_lines()
		assert.is_truthy(lines[#lines]:match("ft=help"))
	end)

	it("stays inside 78 columns", function()
		local wide = {}
		for lnum, line in ipairs(help_lines()) do
			if vim.fn.strdisplaywidth(line) > 78 then
				wide[#wide + 1] = ("line %d is %d wide"):format(lnum, vim.fn.strdisplaywidth(line))
			end
		end
		assert.same({}, wide)
	end)

	it("generates helptags without complaint", function()
		local out = vim.fn.execute("helptags " .. vim.fn.fnameescape(root .. "/doc"))
		assert.equals("", vim.trim(out))
	end)

	it("documents every command the plugin defines", function()
		local plugin = table.concat(vim.fn.readfile(root .. "/plugin/draven.lua"), "\n")
		local text = help_text()

		local missing = {}
		for name in plugin:gmatch('nvim_create_user_command%("(%w+)"') do
			if not text:find("*:" .. name .. "*", 1, true) then
				missing[#missing + 1] = name
			end
		end

		assert.same({}, missing, "commands without a help tag")
	end)

	it("documents every default keymap", function()
		local text = help_text()

		local missing = {}
		for action, lhs in pairs(config.options.keymaps) do
			if lhs and not text:find(lhs, 1, true) then
				missing[#missing + 1] = ("%s (%s)"):format(action, lhs)
			end
		end

		assert.same({}, missing, "keymaps missing from the help file")
	end)

	it("documents every highlight group", function()
		local source = table.concat(vim.fn.readfile(root .. "/lua/draven/ui/highlights.lua"), "\n")
		local text = help_text()

		local missing = {}
		for group in source:gmatch("\n\t(Draven%w+) = ") do
			if not text:find(group, 1, true) then
				missing[#missing + 1] = group
			end
		end

		assert.same({}, missing, "highlight groups missing from the help file")
	end)

	it("lists every section in its own contents", function()
		local text = help_text()

		local missing = {}
		for tag in text:gmatch("\n%d+%.%s[A-Z][A-Z ]-%s+%*(draven%-[%w%-]+)%*") do
			if not text:find("|" .. tag .. "|", 1, true) then
				missing[#missing + 1] = tag
			end
		end

		assert.same({}, missing, "sections missing from the contents")
	end)
end)

describe("readme", function()
	local readme = root .. "/README.md"

	it("exists", function()
		assert.equals(1, vim.fn.filereadable(readme))
	end)

	it("documents every command", function()
		local plugin = table.concat(vim.fn.readfile(root .. "/plugin/draven.lua"), "\n")
		local text = table.concat(vim.fn.readfile(readme), "\n")

		local missing = {}
		for name in plugin:gmatch('nvim_create_user_command%("(%w+)"') do
			if not text:find(":" .. name, 1, true) then
				missing[#missing + 1] = name
			end
		end

		assert.same({}, missing, "commands missing from the README")
	end)

	it("documents every keymap action", function()
		local source = table.concat(vim.fn.readfile(root .. "/lua/draven/ui/init.lua"), "\n")
		local action_table =
			assert(source:match("%-%-%- Action table.-\nactions = {(.-)\n}\n\nreturn M"))
		local text = table.concat(vim.fn.readfile(readme), "\n")

		local missing = {}
		for action in action_table:gmatch("\n\t([%w_]+) = {") do
			if not text:find("`" .. action .. "`", 1, true) then
				missing[#missing + 1] = action
			end
		end

		assert.same({}, missing, "keymap actions missing from the README")
	end)
end)
