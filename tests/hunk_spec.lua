local diff = require("draven.core.diff")
local hunk = require("draven.core.hunk")

---@return draven.Hunk
local function build(lines_text, path)
	local files = diff.parse(table.concat({
		"diff --git a/x.go b/x.go",
		"--- a/x.go",
		"+++ b/x.go",
		lines_text,
	}, "\n"))
	return hunk.build(path or files[1].path, files[1].hunks[1], 1)
end

describe("hunk images", function()
	it("splits pre- and post-image", function()
		local h = build(table.concat({
			"@@ -1,3 +1,3 @@",
			" keep",
			"-before",
			"+after",
			" tail",
		}, "\n"))

		assert.same({ "keep", "after", "tail" }, hunk.post_image(h.lines))
		assert.same({ "keep", "before", "tail" }, hunk.pre_image(h.lines))
		assert.equals(1, h.added)
		assert.equals(1, h.removed)
	end)

	it("reports the post-image line range", function()
		local h = build(table.concat({
			"@@ -10,2 +10,3 @@",
			" a",
			"+b",
			" c",
		}, "\n"))

		local first, last = hunk.new_range(h)
		assert.equals(10, first)
		assert.equals(12, last)
	end)

	it("reports an empty range for a pure deletion", function()
		local h = build(table.concat({
			"@@ -1,2 +0,0 @@",
			"-a",
			"-b",
		}, "\n"))

		local first, last = hunk.new_range(h)
		assert.equals(0, first)
		assert.equals(0, last)
	end)
end)

describe("hunk.normalize", function()
	it("drops blank and whitespace-only lines", function()
		assert.same({}, hunk.normalize({ "", "   \t " }))
	end)

	it("strips trailing whitespace", function()
		assert.same(hunk.normalize({ "foo" }), hunk.normalize({ "foo   " }))
	end)

	it("reduces any indent style to the same nesting ladder", function()
		local block = { "func f() {", "\tif x {", "\t\treturn 1", "\t}", "}" }

		local two_space = { "func f() {", "  if x {", "    return 1", "  }", "}" }
		local four_space = { "func f() {", "    if x {", "        return 1", "    }", "}" }

		assert.same(hunk.normalize(block), hunk.normalize(two_space))
		assert.same(hunk.normalize(block), hunk.normalize(four_space))
	end)

	it("tells different nesting structure apart", function()
		assert.are_not.same(
			hunk.normalize({ "a", "\tb", "\tc" }),
			hunk.normalize({ "a", "\tb", "\t\tc" })
		)
	end)

	it("preserves relative nesting, not absolute depth", function()
		-- Documented limitation: with the unit derived from the hunk itself,
		-- a block indented one level and the same block indented two are
		-- indistinguishable. Deeper structure is what carries the signal.
		assert.same(hunk.normalize({ "a", "\tb" }), hunk.normalize({ "a", "\t\tb" }))
	end)

	it("handles a block with no indentation at all", function()
		assert.same({ "0\1a", "0\1b" }, hunk.normalize({ "a", "b" }))
	end)
end)

describe("hunk content addressing", function()
	it("gives identical hunks identical keys", function()
		local body = table.concat({
			"@@ -1,2 +1,2 @@",
			" keep",
			"-before",
			"+after",
		}, "\n")

		assert.equals(build(body).content_hash, build(body).content_hash)
		assert.equals(build(body).anchor_key, build(body).anchor_key)
	end)

	it("changes both keys when the post-image changes", function()
		local a = build(table.concat({ "@@ -1,1 +1,1 @@", "-x", "+alpha" }, "\n"))
		local b = build(table.concat({ "@@ -1,1 +1,1 @@", "-x", "+beta" }, "\n"))

		assert.are_not.equals(a.content_hash, b.content_hash)
		assert.are_not.equals(a.anchor_key, b.anchor_key)
	end)

	it("ignores the pre-image, so re-reaching the same result reuses the key", function()
		-- Two different edits landing on the same final text are the same code
		-- to review, so the mark should survive.
		local a = build(table.concat({ "@@ -1,1 +1,1 @@", "-one", "+final" }, "\n"))
		local b = build(table.concat({ "@@ -1,1 +1,1 @@", "-two", "+final" }, "\n"))

		assert.equals(a.content_hash, b.content_hash)
	end)

	it("survives reindentation through the anchor key but not the exact hash", function()
		local spaces = build(table.concat({
			"@@ -1,2 +1,2 @@",
			" func f() {",
			"+  return 1",
		}, "\n"))

		local tabs = build(table.concat({
			"@@ -1,2 +1,2 @@",
			" func f() {",
			"+\treturn 1",
		}, "\n"))

		assert.equals(spaces.anchor_key, tabs.anchor_key)
		assert.are_not.equals(spaces.content_hash, tabs.content_hash)
	end)

	it("survives blank-line churn through the anchor key", function()
		local without = build(table.concat({
			"@@ -1,2 +1,2 @@",
			" a",
			"+b",
		}, "\n"))

		local with = build(table.concat({
			"@@ -1,4 +1,4 @@",
			" a",
			"+",
			"+b",
			"+   ",
		}, "\n"))

		assert.equals(without.anchor_key, with.anchor_key)
	end)

	it("separates identical text in different files", function()
		local body = table.concat({ "@@ -1,1 +1,1 @@", "-x", "+y" }, "\n")

		assert.are_not.equals(build(body, "a.go").content_hash, build(body, "b.go").content_hash)
		assert.are_not.equals(build(body, "a.go").anchor_key, build(body, "b.go").anchor_key)
	end)
end)
