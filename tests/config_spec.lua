local config = require("draven.config")

describe("default keymaps", function()
	it("only maps the core review loop", function()
		assert.same({
			comment = "<leader>rc",
			delta = "<leader>rd",
			export = "<leader>rx",
			list_findings = "<leader>rq",
			mark_hunk = "<leader>rr",
			next_hunk = "<leader>rn",
			open_entry = "<CR>",
			prev_hunk = "<leader>rp",
			refresh = "<leader>rR",
			toggle_panel = "<leader>rw",
			toggle_resolved = "<leader>rt",
			unmark_hunk = "<leader>ru",
		}, config.defaults().keymaps)
	end)

	it("allows an unbound action to be configured", function()
		local options = config.setup({
			keymaps = { delete_finding = "<leader>rX" },
		})

		assert.equals("<leader>rX", options.keymaps.delete_finding)
	end)
end)
