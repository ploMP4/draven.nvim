# draven.nvim

[![CI](https://github.com/ploMP4/draven.nvim/actions/workflows/ci.yml/badge.svg)](https://github.com/ploMP4/draven.nvim/actions/workflows/ci.yml)

Review a diff in Neovim, keep your place across rewrites, and export concise,
structured feedback for the agent.

<img width="860" height="484" alt="demo" src="https://github.com/user-attachments/assets/af71bd2f-74cb-4c80-a083-94b7812b9ce8" />

Reviewing code that an agent wrote is iterative. You read it, you send your
findings back, it rewrites, and then you read it again, usually three or four
times on the same changeset. Most tools track review state per file and drop
the flag as soon as the file changes, so the third pass ends up costing you as
much as the first one did.

draven tracks that state per hunk instead, keyed to a hash of the hunk's
contents. When the agent rewrites one hunk of a file you have already read,
your marks on the rest of it survive and only the hunk that actually changed
goes stale.

## Requirements

- Neovim 0.10+ (developed against 0.12)
- git

## Install

Calling `require("draven").setup()` is optional, since it only exists to
change the defaults.

### [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  "ploMP4/draven.nvim",
  cmd = { "Draven", "DravenToggle", "DravenStatus" },
  keys = {
    { "<leader>ro", "<cmd>Draven<cr>", desc = "[R]eview [O]pen" },
  },
  opts = {},
}
```

### [packer.nvim](https://github.com/wbthomason/packer.nvim)

```lua
use({
  "ploMP4/draven.nvim",
  config = function()
    require("draven").setup()
  end,
})
```

### [vim-plug](https://github.com/junegunn/vim-plug)

```vim
Plug 'ploMP4/draven.nvim'
```

draven sets no global mappings of its own, so unless you let lazy.nvim define
one through `keys` above, bind opening a review yourself:

```lua
vim.keymap.set("n", "<leader>ro", "<cmd>Draven<cr>", { desc = "[R]eview [O]pen" })
```

## Usage

```vim
:Draven                  " working tree vs HEAD, the usual case
:Draven main             " working tree vs main
:Draven HEAD~3..HEAD     " a commit range
:Draven main...HEAD      " everything since the branch point

:DravenToggle            " open or close
:DravenClose             " close and save state
:DravenExport            " findings to the clipboard, as a prompt for the agent
:DravenFindings          " findings into the quickfix list
:DravenStatus!           " a per-file breakdown, without opening anything
:DravenReset             " throw away this review's marks and findings
```

`:help draven` has the rest.

`:Draven` opens a tab with the changeset on the left and the diff on the right.
The diff is your real file buffer with decorations drawn on top of it, never a
copy, so `gd`, hover, `]c`, search and every mapping you already have keep
working.

### Keys

These are all buffer-local to the review:

| Key | Action | Does |
| --- | --- | --- |
| `<leader>rr` | `mark_hunk` | mark the hunk read, then jump to the next unread one |
| `<leader>ru` | `unmark_hunk` | unmark the hunk |
| `<leader>rn` | `next_hunk` | jump to the next unread hunk, across files |
| `<leader>rp` | `prev_hunk` | jump to the previous unread hunk, across files |
| `<leader>rd` | `delta` | show what changed in a stale hunk since you approved it |
| `<leader>rc` | `comment` | write a finding on this line, or edit the one here |
| `<leader>rt` | `toggle_resolved` | toggle the finding resolved |
| `<leader>rv` | `toggle_finding` | expand or collapse the finding body |
| `<leader>rX` | `delete_finding` | delete the finding under the cursor |
| `<leader>rq` | `list_findings` | load all findings into the quickfix list |
| `<leader>rx` | `export` | copy findings as a prompt for the agent |
| `<leader>rR` | `refresh` | rebuild from git, keeping every mark |
| `<leader>rw` | `toggle_panel` | hide the panel, or bring it back |
| `<CR>` | `open_entry` | panel only: open a file, or fold a directory |

Use Neovim's normal window and fold commands for everything else. Less common
operations are available through commands or can be assigned in `keymaps` if
you want them.

The following actions have no default mapping, but can be enabled the same way:

| Action | Does |
| --- | --- |
| `mark_file` / `mark_all` | mark the current file / entire review read |
| `next_stale` | jump to the next stale hunk |
| `next_file` / `prev_file` | move between files |
| `toggle_fold` | toggle unchanged-code folds |
| `focus_panel` | focus the changeset panel |
| `quit` | close the review and save |
| `collapse_dir` / `expand_dir` / `toggle_dir` | change the panel directory fold |
| `collapse_all` / `expand_all` | fold or unfold every panel directory |

Progress is counted in hunks rather than files, so `2/5` on a file means that
three of its hunks are still unread. Unchanged code is folded away by default,
which means a 900-line file with three hunks in it reads as just those three
hunks.

### The re-review loop

Read a file, send your findings to the agent and let it rewrite. Then reopen
the review, or hit `<leader>rR`:

```
 draven                                  ↻ marks a hunk that changed
 working tree ← HEAD                       since you read it
 1/2 hunks · 50%
 ↻ 1 changed since you read it
 ─────────────────────────────
 ▾ auth/
   ↻ middleware.go            1/2
```

The hunk that was not touched stays `✓`. On the one that did change,
`<leader>rd` shows you what changed since you approved it rather than the whole
hunk again:

```
 ↻  auth/middleware.go · hunk 1
 approved 14 minutes ago · +2/-1 since

 @@ -2,7 +2,8 @@
   	 tok := r.Header.Get("Authorization")
   	 if tok == "" {
 -		 return ErrEmpty
 +		 log.Warn("empty token")
 +		 return ErrEmpty.WithContext(r)
   }
```

Large deletion blocks are shortened inline because virtual lines cannot be
cursor-scrolled when they exceed the window. Their summary points to
`<leader>rd`, which opens the complete hunk in a normal scrollable buffer.

### Findings

`<leader>rc` opens a scratch buffer in a float. It is just text, so your insert
mappings, abbreviations and undo all work in it. `<Tab>` cycles through the
severities, `<C-s>` or `:w` saves, and `<Esc>` throws it away.

Findings are rendered below the line they point at. New findings start as a
one-line summary; `<leader>rv` expands one into a clearly separate header and
wrapped body without covering source lines. Use
`ui.finding_display = "above"` for the old placement, or `"eol"` for summaries
at the end of the source line.

They are anchored to a line of code rather than to a line number, so when the
agent rewrites the file a finding follows the line it was written about. If
that line is genuinely gone the finding is marked as orphaned, instead of
being quietly re-pointed at whatever moved into its place. Orphans remain in a
dedicated panel section: `<CR>` views or edits one, and `<leader>rX` deletes it.

`<leader>rx` (or `:DravenExport`) puts the lot on your clipboard as something
you can paste straight into an agent:

````markdown
Code review of working tree against HEAD.

4 of 12 hunks read; 3 findings below.
Address them in order. Do not change anything else.

## Blocking — these must be fixed

### auth/token.go:52

```go
	if tok == "" {
		return ErrEmpty
	}
```

Returning here skips the audit log.
Every other early return calls auditDenied().
````

Resolved findings stay in the state file but they are left out of the prompt.
`<leader>rq` (or `:DravenFindings`) puts them all in the quickfix list instead,
typed by severity (`E`, `W` or `I`), so `]q` and `:cdo` work on them.

## API

```lua
local draven = require("draven")

-- Blocking: convenient from `:lua` and tests, never from a mapping.
local cs = draven.changeset()
local cs = draven.changeset({ rev = "main...HEAD", cwd = "/path/to/repo" })

-- Async: how everything internal calls it.
draven.changeset({ rev = "main" }, function(err, cs)
  if err then return end
  print(draven.summary(cs))
end)
```

A changeset is plain data:

```lua
{
  root      = "/home/you/project",
  revspec   = { kind = "worktree", base = "HEAD", head = nil, ... },
  base_rev  = "a1b2c3...",   -- nil for a commit range
  unborn    = false,          -- true when HEAD has no commits yet
  files     = { ... },
  stats     = { files = 14, hunks = 62, added = 310, removed = 88, ... },
}
```

Each file carries `path`, `old_path`, `status` (`added`, `modified`, `deleted`,
`renamed`, `copied` or `mode`), `binary`, `untracked`, `ignored`, and its
hunks. Each hunk carries its line ranges, its parsed lines with both the old
and the new line numbers, and the two keys that review state hangs off. Those
are `content_hash`, which is exact, and `anchor_key`, which ignores whitespace
so that reformatting does not lose your marks. `:help draven-states` explains
how a hunk ends up reviewed, stale or unread.

Iterate every reviewable hunk, ignored files skipped:

```lua
for file, hunk in require("draven.core.changeset").hunks(cs) do
  print(file.path, hunk.index, hunk.content_hash)
end
```

## Configuration

Defaults shown:

```lua
require("draven").setup({
  base = "HEAD",              -- default base for a working-tree review
  context = 3,                -- lines of context per hunk
  include_untracked = true,   -- new files the agent created count too
  max_file_bytes = 1024*1024, -- larger untracked files are listed, not read
  log_level = vim.log.levels.INFO,

  git = { bin = "git", timeout_ms = 15000 },

  ignore = {
    enabled = true,
    patterns = { "**/*.lock", "**/go.sum", "**/node_modules/**", ... },
  },

  ui = {
    panel = { width = 38, position = "left" },
    signs = { reviewed = "✓", unread = "○", partial = "◐", ignored = "⊘", hunk = "╎" },
    fold_unchanged = true,
    fold_context = 6,
    finding_display = "below",
    max_inline_deletions = 8,
  },

  keymaps = {              -- set any entry to false to skip it
    mark_hunk = "<leader>rr",
    -- ...see the table above
  },
})
```

Review state lives in `<gitdir>/draven/<revspec>.json`. It is plain JSON, one
file per review target, keyed by content hash.

Ignored files stay visible in the changeset but they are left out of the
totals, so a regenerated lockfile cannot make your review progress look worse
than it is. Note that `ignore.patterns` replaces the default list rather than
extending it. The glob syntax supports `**/` for zero or more directories,
along with `**`, `*` and `?`.

## Development

```sh
make test    # clones plenary into .tests/ if you don't already have it
make lint    # stylua --check
make fmt
```
