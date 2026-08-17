# draven

A code review surface for Neovim that remembers what you already read.

Reviewing code an agent wrote is not the same job as reviewing a colleague's
pull request. Diffs arrive large and across many files, and review is
iterative — you read, you send findings back, the agent rewrites, you read
again. Every existing tool marks *"file viewed"* and drops the flag the moment
the file changes, so round three costs as much as round one.

draven marks **hunks** reviewed, keyed to a hash of their content. When the
agent rewrites one hunk of a file you already read, the marks on the other
hunks survive and only the changed one goes stale.

> The review surface works — panel, diff decoration, hunk navigation,
> progress and persistence. Stale detection, the v1→v2 delta view and
> findings are still to come.

## Requirements

- Neovim 0.10+ (developed against 0.12)
- git

## Install

Install `ploMP4/draven` with your plugin manager of choice. Calling
`require("draven").setup()` is optional — it only exists to change defaults.

draven sets no global mappings, so bind opening a review yourself:

```lua
vim.keymap.set("n", "<leader>ro", "<cmd>Draven<cr>", { desc = "[R]eview [O]pen" })
```

## Usage

```vim
:Draven                  " working tree vs HEAD — the agent-output case
:Draven main             " working tree vs main
:Draven HEAD~3..HEAD     " a commit range
:Draven main...HEAD      " everything since the branch point

:DravenToggle            " open or close
:DravenClose             " close and save state
:DravenStatus!           " a per-file breakdown, without opening anything
```

`:Draven` opens a tab: the changeset on the left, the diff on the right. The
diff is your real file buffer with decorations on top, so `gd`, hover, `]c`,
search and every mapping you already have keep working.

### Keys

Buffer-local to the review:

| Key | Does |
| --- | --- |
| `<leader>rr` | mark the hunk read, then jump to the next unread one |
| `<leader>rf` | mark the whole file read |
| `<leader>ru` | unmark the hunk |
| `<leader>ra` | mark everything read |
| `<leader>rn` / `<leader>rp` | next / previous unread hunk, across files |
| `]f` / `[f` | next / previous file |
| `<leader>rz` | toggle the unchanged-code folds |
| `<leader>rR` | rebuild from git, keeping every mark |
| `<leader>re` | jump to the panel |
| `<leader>rq` | close and save |
| `<CR>` | panel only: open a file, or fold a directory |

Progress is counted in hunks, not files: `2/5` on a file means three hunks in
it are still unread. Unchanged code folds away by default, so a 900-line file
with three hunks reads as three hunks.

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

Each file carries `path`, `old_path`, `status`
(`added`/`modified`/`deleted`/`renamed`/`copied`/`mode`), `binary`, `untracked`,
`ignored`, and its hunks. Each hunk carries its line ranges, its parsed lines
with both old and new line numbers, and the two keys review state hangs off:

| Key | Normalisation | Used for |
| --- | --- | --- |
| `content_hash` | none — exact post-image | equal means definitely unchanged |
| `anchor_key` | indent collapsed to a depth count, trailing whitespace and blank lines dropped | relocating a hunk that moved or got reindented |

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
  include_untracked = true,   -- new files an agent created are the point
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

Review state lives in `<gitdir>/draven/<revspec>.json` — plain JSON, one file
per review target, keyed by content hash.

Ignored files stay visible in the changeset but are excluded from the totals,
so a regenerated lockfile can never make review progress look worse.
`ignore.patterns` replaces the default list rather than extending it; glob
syntax is `**/` (zero or more directories), `**`, `*` and `?`.

## Design

Two constraints drive everything:

**Never claim something is reviewed when it isn't.** When anchoring is
uncertain the hunk goes stale. A false "unread" costs ten seconds; a false
"reviewed" costs trust, and an untrustworthy review tool is worthless.

**Don't fight Neovim.** Rendering will be decoration-only over real buffers, so
`gd`, LSP, treesitter and your own keymaps keep working. That constraint is why
`core/` contains no Neovim UI calls at all.

```
lua/draven/
├── init.lua              public API
├── config.lua            defaults and merge
├── session.lua           a changeset joined to its marks
├── state.lua             JSON persistence, keyed by content hash
├── health.lua            :checkhealth draven
├── core/                 pure model — no UI, no editor state
│   ├── git.lua           async vim.system plumbing
│   ├── diff.lua          unified diff parser
│   ├── hunk.lua          hunk model + content addressing
│   ├── changeset.lua     the assembled review target
│   └── ignore.lua        generated-file rules
├── ui/
│   ├── init.lua          the review tab: layout, keymaps, actions
│   ├── panel.lua         the changeset tree
│   ├── view.lua          the diff window and its buffers
│   ├── render.lua        extmark decoration and folds
│   └── highlights.lua    groups, linked to your colorscheme
└── util/                 async runtime, fs, glob, log
```

Opening a 257-file, 607-hunk changeset takes ~140 ms; marking a hunk with a
full panel repaint takes ~10 ms.

## Development

```sh
make test    # clones plenary into .tests/ if you don't already have it
make lint    # stylua --check
make fmt
```

## Scope

Deliberately out of scope: staging, commits, branch management, conflict
resolution. draven is not a git client.
