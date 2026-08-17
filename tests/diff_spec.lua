local diff = require("draven.core.diff")

describe("diff.parse", function()
	it("returns nothing for empty input", function()
		assert.same({}, diff.parse(""))
		assert.same({}, diff.parse(nil))
	end)

	it("parses a modification with correct line numbers", function()
		local files = diff.parse(table.concat({
			"diff --git a/auth/token.go b/auth/token.go",
			"index 1111111..2222222 100644",
			"--- a/auth/token.go",
			"+++ b/auth/token.go",
			"@@ -38,4 +38,5 @@ func Validate(tok string) error {",
			" \tclaims, err := parse(tok)",
			"-\tif err != nil {",
			"+\tif err != nil || claims == nil {",
			"+\t\tlog.Warn(\"bad token\")",
			" \t\treturn ErrInvalid",
			" \t}",
			"",
		}, "\n"))

		assert.equals(1, #files)

		local f = files[1]
		assert.equals("auth/token.go", f.path)
		assert.is_nil(f.old_path)
		assert.equals("modified", f.status)
		assert.is_false(f.binary)
		assert.equals(1, #f.hunks)

		local h = f.hunks[1]
		assert.equals(38, h.old_start)
		assert.equals(4, h.old_count)
		assert.equals(38, h.new_start)
		assert.equals(5, h.new_count)
		assert.equals("func Validate(tok string) error {", h.section)
		assert.equals(6, #h.lines)

		assert.equals("context", h.lines[1].kind)
		assert.equals(38, h.lines[1].old_lnum)
		assert.equals(38, h.lines[1].new_lnum)

		assert.equals("delete", h.lines[2].kind)
		assert.equals(39, h.lines[2].old_lnum)
		assert.is_nil(h.lines[2].new_lnum)

		assert.equals("add", h.lines[3].kind)
		assert.equals(39, h.lines[3].new_lnum)
		assert.is_nil(h.lines[3].old_lnum)

		assert.equals("add", h.lines[4].kind)
		assert.equals(40, h.lines[4].new_lnum)

		-- Context after the change resumes on both sides, now offset by one.
		assert.equals("context", h.lines[5].kind)
		assert.equals(40, h.lines[5].old_lnum)
		assert.equals(41, h.lines[5].new_lnum)

		assert.equals("context", h.lines[6].kind)
		assert.equals(41, h.lines[6].old_lnum)
		assert.equals(42, h.lines[6].new_lnum)
	end)

	it("treats a hunk as finished once its line counts are satisfied", function()
		-- The blank line after the hunk must not be swallowed as context.
		local files = diff.parse(table.concat({
			"diff --git a/a.txt b/a.txt",
			"--- a/a.txt",
			"+++ b/a.txt",
			"@@ -1,1 +1,1 @@",
			"-one",
			"+ONE",
			"@@ -5,1 +5,1 @@",
			"-five",
			"+FIVE",
			"",
		}, "\n"))

		assert.equals(2, #files[1].hunks)
		assert.equals(2, #files[1].hunks[1].lines)
		assert.equals(2, #files[1].hunks[2].lines)
	end)

	it("handles omitted counts in the hunk header", function()
		local files = diff.parse(table.concat({
			"diff --git a/a.txt b/a.txt",
			"--- a/a.txt",
			"+++ b/a.txt",
			"@@ -3 +3 @@",
			"-old",
			"+new",
		}, "\n"))

		local h = files[1].hunks[1]
		assert.equals(3, h.old_start)
		assert.equals(1, h.old_count)
		assert.equals(3, h.new_start)
		assert.equals(1, h.new_count)
	end)

	it("parses an addition", function()
		local files = diff.parse(table.concat({
			"diff --git a/new.txt b/new.txt",
			"new file mode 100644",
			"index 0000000..3333333",
			"--- /dev/null",
			"+++ b/new.txt",
			"@@ -0,0 +1,2 @@",
			"+alpha",
			"+beta",
		}, "\n"))

		local f = files[1]
		assert.equals("added", f.status)
		assert.equals("new.txt", f.path)
		assert.is_nil(f.old_path)
		assert.equals(2, #f.hunks[1].lines)
		assert.equals(1, f.hunks[1].lines[1].new_lnum)
		assert.equals(2, f.hunks[1].lines[2].new_lnum)
	end)

	it("parses a deletion and keeps an addressable path", function()
		local files = diff.parse(table.concat({
			"diff --git a/gone.txt b/gone.txt",
			"deleted file mode 100644",
			"index 3333333..0000000",
			"--- a/gone.txt",
			"+++ /dev/null",
			"@@ -1,2 +0,0 @@",
			"-alpha",
			"-beta",
		}, "\n"))

		local f = files[1]
		assert.equals("deleted", f.status)
		assert.equals("gone.txt", f.path)
		assert.equals(2, #f.hunks[1].lines)
	end)

	it("parses a rename with content changes", function()
		local files = diff.parse(table.concat({
			"diff --git a/old/name.go b/new/name.go",
			"similarity index 87%",
			"rename from old/name.go",
			"rename to new/name.go",
			"--- a/old/name.go",
			"+++ b/new/name.go",
			"@@ -1,1 +1,1 @@",
			"-package old",
			"+package new",
		}, "\n"))

		local f = files[1]
		assert.equals("renamed", f.status)
		assert.equals("new/name.go", f.path)
		assert.equals("old/name.go", f.old_path)
		assert.equals(87, f.similarity)
		assert.equals(1, #f.hunks)
	end)

	it("parses a rename with no content change", function()
		local files = diff.parse(table.concat({
			"diff --git a/old.txt b/new.txt",
			"similarity index 100%",
			"rename from old.txt",
			"rename to new.txt",
		}, "\n"))

		local f = files[1]
		assert.equals("renamed", f.status)
		assert.equals("new.txt", f.path)
		assert.equals("old.txt", f.old_path)
		assert.equals(0, #f.hunks)
	end)

	it("flags binary files and recovers their path from the header", function()
		local files = diff.parse(table.concat({
			"diff --git a/img/logo.png b/img/logo.png",
			"index 1111111..2222222 100644",
			"Binary files a/img/logo.png and b/img/logo.png differ",
		}, "\n"))

		local f = files[1]
		assert.is_true(f.binary)
		assert.equals("img/logo.png", f.path)
		assert.equals(0, #f.hunks)
	end)

	it("detects a mode-only change", function()
		local files = diff.parse(table.concat({
			"diff --git a/run.sh b/run.sh",
			"old mode 100644",
			"new mode 100755",
		}, "\n"))

		assert.equals("mode", files[1].status)
		assert.equals("run.sh", files[1].path)
	end)

	it("marks a missing trailing newline", function()
		local files = diff.parse(table.concat({
			"diff --git a/a.txt b/a.txt",
			"--- a/a.txt",
			"+++ b/a.txt",
			"@@ -1,1 +1,1 @@",
			"-old",
			"\\ No newline at end of file",
			"+new",
			"\\ No newline at end of file",
		}, "\n"))

		local lines = files[1].hunks[1].lines
		assert.is_true(lines[1].no_newline)
		assert.is_true(lines[2].no_newline)
	end)

	it("does not mistake a deleted line for a header", function()
		-- `--- three dashes` inside a hunk is a deletion, not a path line.
		local files = diff.parse(table.concat({
			"diff --git a/doc.md b/doc.md",
			"--- a/doc.md",
			"+++ b/doc.md",
			"@@ -1,2 +1,2 @@",
			"--- old heading",
			"+++ new heading",
			" body",
		}, "\n"))

		local f = files[1]
		assert.equals("doc.md", f.path)

		local lines = f.hunks[1].lines
		assert.equals("delete", lines[1].kind)
		assert.equals("-- old heading", lines[1].text)
		assert.equals("add", lines[2].kind)
		assert.equals("++ new heading", lines[2].text)
		assert.equals("context", lines[3].kind)
	end)

	it("parses several files in one diff", function()
		local files = diff.parse(table.concat({
			"diff --git a/one.txt b/one.txt",
			"--- a/one.txt",
			"+++ b/one.txt",
			"@@ -1,1 +1,1 @@",
			"-a",
			"+b",
			"diff --git a/two.txt b/two.txt",
			"--- a/two.txt",
			"+++ b/two.txt",
			"@@ -1,1 +1,1 @@",
			"-c",
			"+d",
		}, "\n"))

		assert.equals(2, #files)
		assert.equals("one.txt", files[1].path)
		assert.equals("two.txt", files[2].path)
	end)

	it("unquotes paths containing unusual characters", function()
		local files = diff.parse(table.concat({
			'diff --git "a/od\\303\\251.txt" "b/od\\303\\251.txt"',
			'--- "a/od\\303\\251.txt"',
			'+++ "b/od\\303\\251.txt"',
			"@@ -1,1 +1,1 @@",
			"-a",
			"+b",
		}, "\n"))

		assert.equals("odé.txt", files[1].path)
	end)
end)
