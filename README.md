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

> The model is built and tested; there is no UI yet. `:Draven` reports what
> it found so the model can be exercised against real repos.

## Requirements

- Neovim 0.10+ (developed against 0.12)
- git

## Install

Install `ploMP4/draven` with your plugin manager of choice. Calling
`require("draven").setup()` is optional — it only exists to change defaults.

## Usage

```vim
:Draven                  " working tree vs HEAD — the agent-output case
:Draven main             " working tree vs main
:Draven HEAD~3..HEAD     " a commit range
:Draven main...HEAD      " everything since the branch point
:Draven!                 " same, with a per-file breakdown
```

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
})
```

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
├── health.lua            :checkhealth draven
├── core/                 pure model — no UI, no editor state
│   ├── git.lua           async vim.system plumbing
│   ├── diff.lua          unified diff parser
│   ├── hunk.lua          hunk model + content addressing
│   ├── changeset.lua     the assembled review target
│   └── ignore.lua        generated-file rules
└── util/                 async runtime, fs, glob, log
```

## Development

```sh
make test    # clones plenary into .tests/ if you don't already have it
make lint    # stylua --check
make fmt
```

## Scope

Deliberately out of scope: staging, commits, branch management, conflict
resolution. draven is not a git client.
