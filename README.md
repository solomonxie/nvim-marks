# nvim-marks

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Neovim](https://img.shields.io/badge/Neovim-0.5%2B-blue.svg)](https://neovim.io/)

Persistent marks and annotations for Neovim that survive code changes, branch switches, and file moves.

## ✨ Features

- [x] **Persistent Marks**: Marks that survive across sessions, branch switches, and code changes
- [x] **Smart Matching**: Finds each line again by diffing against the saved file and matching line text plus surrounding lines
- [x] **Branches & Worktrees**: One store per repo, shared by all worktrees; marks whose line isn't on the current branch are kept and come back later
- [x] **Dual Support**: Works with both Vim marks (a-z, A-Z) and Extmarks for annotations
- [x] **Visual Indicators**: Sign column shows all marks and notes at a glance
- [x] **Automatic**: Save/restore marks automatically on buffer events
- [ ] Smart match each mark on restoring each buffer
- [ ] Match marks after file renamed

<img width="936" height="607" alt="Xnip2026-01-20_10-26-32" src="https://github.com/user-attachments/assets/0f1b306a-e61c-42a3-be61-33a4bb9ec3ac" />


## 📋 Requirements

- **Neovim** 0.5+ (for extmarks support)
- **Neovim** 0.9+ (`vim.diff`)
- **Git** (optional, to share marks across worktrees of a repo)

## 🚀 Installation

### [vim-plug](https://github.com/junegunn/vim-plug)

```vim
Plug 'solomonxie/nvim-marks'
```

### [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  "solomonxie/nvim-marks",
  config = function()
    -- Plugin is configured automatically
    -- Optional: add custom keymaps or settings
  end,
}
```

### [packer.nvim](https://github.com/wbthomason/packer.nvim)

```lua
use {
  "solomonxie/nvim-marks",
  config = function()
    -- Plugin is configured automatically
  end,
}
```

### Manual Installation

1. Clone the repository:
```bash
git clone https://github.com/solomonxie/nvim-marks.git ~/.config/nvim/pack/plugins/start/nvim-marks
```

2. Restart Neovim

## 🎯 Quick Start

1. **Open Marks Window**: Press `m` in any buffer
2. **Add Mark**: Press any letter `a-z`/`A-Z` in the marks window (except `q`, `j`, `k`, used by the window itself)
3. **Add Note**: Press `+` to add an annotation
4. **Delete Mark/Note**: Press `-` on it, then `y` to confirm
5. **Quit**: Press `q` to close the marks window

## 📖 Usage

### Basic Workflow

```vim
" Open marks management window
m

" In the marks window:
" Press a-z     - Add a local mark at current line (except q, j, k)
" Press A-Z     - Add a global mark at current line
" Press <CR>    - Jump to the mark/note under the cursor
" Press +       - Add a note/annotation
" Press -       - Delete the mark/note under the cursor (asks y/n)
" Press *       - List all marks in current file
" Press q       - Quit marks window
```

### Mark Types

- **Local Marks** (`a-z`): File-specific marks
- **Global Marks** (`A-Z`): Cross-file marks that work across your project
- **Notes**: Rich annotations with multi-line content

### Navigation

```vim
" 'A  " Jump to any mark (standard Vim mark navigation)
" ma  " Jump to mark 'a'
" mA  " Jump to global mark 'A'
```

## ⚙️ Configuration

Works out of the box. Marks are saved to `<dir>/<repo>/marks-history.json`, one file per repo shared by all its worktrees. `<dir>` defaults to `stdpath('data')/nvim-marks` (e.g. `~/.local/share/nvim/nvim-marks/myapp/marks-history.json`).

```lua
require('nvim-marks').setup({ dir = '~/notes/marks' })
```

Or in Vimscript: `let g:nvim_marks_dir = '~/notes/marks'`.

Notes show at the end of their line, like `local x = 1    -- check this`; a multi-line note is joined with ` | `. To show them on their own lines above instead: `setup({ note_style = 'above' })` (or `let g:nvim_marks_note_style = 'above'`). Change the `    -- ` before an inline note with `note_prefix`.


## 🔧 How It Works

### Why Persistent Marks?

When working on large codebases, it's common to have important annotations, bookmarks, or marks that help navigate and understand the code. However, these marks can be lost when switching branches, pulling updates, or making changes to the code. Persistent marks ensure that these important references are saved and can be restored even after significant changes to the codebase.

### The Challenge of Persistence

If we want to put a mark on a line, we need to first know which line it is. But line numbers change so often, and even the line content may change too. So we need an "anchor" to associate the mark with the line which can survive:

- Line number changes
- Line content changes
- File moves/renames
- Branch switches
- Edits outside of the editor
- And more...

To satisfy all these requirements is really hard, which is why it's so difficult to find a good plugin for this feature.

### Smart Matching Strategy

For each mark and note, nvim-marks saves an anchor: the row, the line's text and 2 lines above and below. It also saves a snapshot of the file's lines. While a file is open, Neovim moves marks itself as you edit; matching only runs when a file is opened:

1. Map the old row through a line diff (`vim.diff`) of the snapshot against the current file. If the line there still has the same text, done.
2. Otherwise look for lines with the same text; the one whose surrounding lines match best wins, then the one closest to where it was expected.
3. Otherwise fuzzy-match text plus surrounding lines within 50 rows of where it was expected.
4. Otherwise it's an orphan: listed in the marks window under "Not found in this version", kept in the store, and tried again every time the file is opened (e.g. after switching back to the branch where the line exists). Delete it with `-`.

### Data Storage

One JSON file per repo holds every file's marks and notes, keyed by the path from the repo root, so `src/a.lua` is the same file in every worktree:

```
~/.local/share/nvim/nvim-marks/
└── your-project-name.json
```

Saving merges into the file (only the current file's entry is replaced), so several nvim instances in different worktrees don't overwrite each other's files. Marks saved by the old version (`.git/persistent_marks/`) are picked up the first time a file is opened.

### Performance Considerations

- **Fast startup**: ~1ms initialization time
- **Efficient matching**: One diff per file, fuzzy matching only near the expected row, no git calls besides one `rev-parse` per folder
- **Minimal overhead**: No impact on normal editing workflow
