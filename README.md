# draven

Review a diff in Neovim and keep your place across rewrites.

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

Install `ploMP4/draven` with your plugin manager of choice. Calling
`require("draven").setup()` is optional, since it only exists to change the
defaults.

draven sets no global mappings, so bind opening a review yourself:

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

| Key | Does |
| --- | --- |
| `<leader>rr` | mark the hunk read, then jump to the next unread one |
| `<leader>rf` | mark the whole file read |
| `<leader>ru` | unmark the hunk |
| `<leader>ra` | mark everything read |
| `<leader>rn` / `<leader>rp` | next / previous unread hunk, across files |
| `<leader>rd` | on a stale hunk: what changed since you approved it |
| `<leader>rs` | jump to the next hunk the agent rewrote under you |
| `<leader>rc` | write a finding on this line (or edit the one here) |
| `<leader>rt` | mark the finding resolved |
| `<leader>rX` | delete the finding |
| `<leader>rl` | all findings into the quickfix list |
| `<leader>rx` | copy findings as a prompt for the agent |
| `]f` / `[f` | next / previous file |
| `<leader>rz` | toggle the unchanged-code folds |
| `<leader>rR` | rebuild from git, keeping every mark |
| `<leader>re` | jump to the panel |
| `<leader>rw` | hide the panel, or bring it back |
| `<leader>rq` | close and save |
| `<CR>` | panel only: open a file, or fold a directory |
| `h` / `l` | panel only: collapse / expand the directory |
| `zM` / `zR` | panel only: collapse / expand every directory |

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

### Findings

`<leader>rc` opens a scratch buffer in a float. It is just text, so your insert
mappings, abbreviations and undo all work in it. `<Tab>` cycles through the
severities, `<C-s>` or `:w` saves, and `<Esc>` throws it away.

Findings are rendered above the line they point at, so a long line cannot hide
them and a comment that spans several lines still shows in full. If you would
rather have them at the end of the line, set `ui.finding_display = "eol"`.

They are anchored to a line of code rather than to a line number, so when the
agent rewrites the file a finding follows the line it was written about. If
that line is genuinely gone the finding is marked as orphaned, instead of
being quietly re-pointed at whatever moved into its place.

`<leader>rx` puts the lot on your clipboard as something you can paste
straight into an agent:

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
`<leader>rl` puts them all in the quickfix list instead, typed by severity
(`E`, `W` or `I`), so `]q` and `:cdo` work on them.

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
