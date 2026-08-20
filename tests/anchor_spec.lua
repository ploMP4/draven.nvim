local anchor = require("draven.core.anchor")

---@return draven.Hunk
local function hunk(opts)
	return {
		id = opts.id or "f.go#1",
		index = 1,
		path = opts.path or "f.go",
		old_start = opts.old_start or 10,
		old_count = opts.old_count or 4,
		new_start = 10,
		new_count = 4,
		section = "",
		lines = {},
		added = 0,
		removed = 0,
		content_hash = opts.content_hash or "hash-a",
		anchor_key = opts.anchor_key or "anchor-a",
	}
end

---@return draven.MarkRecord
local function mark(opts)
	return {
		at = 1,
		path = opts.path or "f.go",
		content_hash = opts.content_hash or "hash-a",
		anchor_key = opts.anchor_key or "anchor-a",
		old_start = opts.old_start,
		old_count = opts.old_count,
	}
end

describe("anchor.overlap", function()
	it("measures shared base lines", function()
		assert.equals(4, anchor.overlap(10, 4, 10, 4))
		assert.equals(2, anchor.overlap(10, 4, 12, 4))
		assert.equals(0, anchor.overlap(10, 4, 14, 4), "adjacent is not overlapping")
		assert.equals(0, anchor.overlap(10, 4, 100, 4))
	end)

	it("treats a pure insertion as the point it was inserted at", function()
		-- `@@ -41,0 +42,3 @@` sits at base line 41 and occupies nothing.
		assert.equals(1, anchor.overlap(41, 0, 41, 0))
		assert.equals(1, anchor.overlap(41, 0, 38, 5))
		assert.equals(0, anchor.overlap(41, 0, 30, 5))
	end)
end)

describe("anchor.classify", function()
	it("is unread when there are no marks", function()
		assert.equals("unread", anchor.classify(hunk({}), nil, {}))
		assert.equals("unread", anchor.classify(hunk({}), {}, {}))
	end)

	it("is reviewed on an exact content match", function()
		local status, origin = anchor.classify(hunk({}), { mark({}) }, {})
		assert.equals("reviewed", status)
		assert.equals("hash-a", origin.content_hash)
	end)

	it("stays reviewed when only whitespace changed", function()
		-- Different bytes, same meaning: reindenting approved code does not
		-- make it unapproved.
		local h = hunk({ content_hash = "hash-reindented" })
		local status = anchor.classify(h, { mark({}) }, {})
		assert.equals("reviewed", status)
	end)

	it("is stale when a different hunk covers the same base lines", function()
		local h = hunk({ content_hash = "hash-rewritten", anchor_key = "anchor-rewritten" })
		local m = mark({ old_start = 10, old_count = 4 })

		local status, origin = anchor.classify(h, { m }, {})
		assert.equals("stale", status)
		assert.equals(m, origin, "stale hunks carry the mark they descend from")
	end)

	it("is unread when nothing it descends from was ever read", function()
		local h = hunk({
			old_start = 200,
			old_count = 3,
			content_hash = "hash-new",
			anchor_key = "anchor-new",
		})

		assert.equals("unread", anchor.classify(h, { mark({ old_start = 10, old_count = 4 }) }, {}))
	end)

	it("picks the mark it overlaps most when a rewrite merges two hunks", function()
		local h = hunk({
			old_start = 10,
			old_count = 20,
			content_hash = "hash-merged",
			anchor_key = "anchor-merged",
		})

		local small =
			mark({ content_hash = "small", anchor_key = "k1", old_start = 10, old_count = 2 })
		local big =
			mark({ content_hash = "big", anchor_key = "k2", old_start = 15, old_count = 10 })

		local status, origin = anchor.classify(h, { small, big }, {})
		assert.equals("stale", status)
		assert.equals("big", origin.content_hash)
	end)

	it("refuses to infer descent once the base has moved", function()
		local h = hunk({ content_hash = "hash-rewritten", anchor_key = "anchor-rewritten" })
		local m = mark({ old_start = 10, old_count = 4 })

		-- Base-side addresses mean nothing against a different base, so the
		-- honest answer is "never seen", not "descends from".
		assert.equals("unread", anchor.classify(h, { m }, { base_stable = false }))

		-- Content addressing still holds, though.
		assert.equals("reviewed", anchor.classify(hunk({}), { m }, { base_stable = false }))
	end)

	it("ignores marks that lost their base-side address", function()
		local h = hunk({ content_hash = "hash-rewritten", anchor_key = "anchor-rewritten" })
		local m = mark({ old_start = nil, old_count = nil })

		assert.equals("unread", anchor.classify(h, { m }, {}))
	end)
end)
