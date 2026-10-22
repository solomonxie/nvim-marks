# nvim-marks

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Neovim](https://img.shields.io/badge/Neovim-0.10%2B-blue.svg)](https://neovim.io/)

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

- **Neovim** 0.10+
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
2. **Add Mark**: Press a capital letter `A-Z` in the marks window (except `G` and `N`); other lowercase keys work as usual there
3. **Add Note**: Press `a` (so `ma` from the code) to add an annotation (or edit the note already on that line)
4. **Edit Note**: Press `e` on a note in the marks window
5. **Delete Mark/Note**: Press `-` on it, then `y` to confirm
6. **Quit**: Press `q` to close the marks window

## 📖 Usage

### Basic Workflow

```vim
" Open marks management window
m

" In the marks window:
" Press A-Z     - Add a global mark at current line (except G, N)
" Press <CR>    - Jump to the mark/note under the cursor
" Press a       - Add a note/annotation, or edit the one on the current line
" Press o       - Open the note under the cursor to edit it, or start the tour under it
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

## 🧭 Guided marks (tours)

A tour walks you through code step by step, like a website tutorial. Put tour files next to `marks.jsonl`, as `<dir>/<repo>/tours-<slug>.jsonl` (shared by every worktree). Any other `.jsonl` there whose first line has a `"tour"` key counts too; `marks.jsonl` and `marks-log.jsonl` never do. The marks window lists them under `# Tours`, above the Anchors section; `<CR>` or `o` on one starts guided mode.

In guided mode the panel shows the tour's name and description, the tour as a numbered tree with `▶` on the current step, and pinned to the bottom of the panel `Current step explanation:` with the step's explanation (gray, wrapped to the panel's width). It stays in view however long the tree is: the tree scrolls above it. One blank line between each part, and the panel is as tall as what it shows, up to its max height; the code window above opens each step's file with the cursor on its line and a green `▶` in the sign column there (the line itself isn't highlighted, your cursor line shows it). The tour reuses that one window and opens each step's file the normal way (`:edit`), so it's an ordinary buffer: filetype, LSP, git signs and your other plugins work as usual. A file the tour opened is closed when it moves to another file, so only one is open at a time (files you already had open are left alone); the current one stays open when you leave. `q` leaves the tour on the current step's file; `Backspace` goes back to the file you started from and the marks window. Keys in the panel: `n` next, `p` previous, `<CR>` jump to the step under the cursor, `Backspace` back to the marks window, `q` / `Ctrl-c` / `Esc` leave. You can move to the code window to read around and come back.

`n` walks the tree depth-first and, after each child, walks back up to its parent before going on, ending back at the root. The `▶` in the numbered tree shows where you are; there is no step counter, and the title says `end of tour` at the last stop:

```
1. A                 n:  A → B → D → B → E → B → A → C → A (end of tour)
2. └─ B
3.    └─ D
4.    └─ E
5. └─ C
```

A step can have several parents (a DAG); it's shown once, under the first parent that reaches it, marked `(shared)`, and walked once there. Cycles are rejected.

Format: one step per line, every line the same shape. The root step comes first and also carries the tour's `tour` (name) and `description`:

```json
{"id":"s1","tour":"Save flow","description":"How a save goes from load to encode","title":"module table","file":"src/store.lua","row":1,"line":"local M = {}","text":"Everything hangs off `M`.","children":["s2","s3"]}
{"id":"s2","title":"encode","file":"src/store.lua","row":5,"line":"local function encode(data)","text":"JSON encoder used by save."}
```

`file` is the path from the repo root; `row` and `line` (the exact code) find the step's line again after edits, like a note. Add `"commit"` (HEAD when the tour was written, e.g. `git rev-parse --short=12 HEAD`) and a step whose line was later rewritten is still found, through the diff since that commit. `text` is the explanation (markdown, `\n` for new lines). The plugin only reads tours: write them by hand, or have an LLM write one. Tours with a separate header line (`{"tour":..., "root":"s1"}` before the steps) still load.

## ⚙️ Configuration

Works out of the box. Marks are saved to `<dir>/<repo>/marks.jsonl`, one file per repo shared by all its worktrees. `<dir>` defaults to `stdpath('data')/nvim-marks` (e.g. `~/.local/share/nvim/nvim-marks/myapp/marks.jsonl`).

```lua
require('nvim-marks').setup({ dir = '~/notes/marks' })
```

Or in Vimscript: `let g:nvim_marks_dir = '~/notes/marks'`.

Files kept inside that folder, under a repo's name (e.g. your own notes in `~/notes/marks/myapp/plan.md`), are treated as part of that repo: their notes go into `~/notes/marks/myapp/marks.jsonl` with the repo's code notes.

The marks window is as tall as its content, from 10 lines up to 40% of the screen height. Change the max with `setup({ height = 0.5 })` or a number of lines, `setup({ height = 25 })` (or `let g:nvim_marks_height = 25`).

The marks file is checked every 10 seconds for changes made elsewhere (another nvim, e.g. in another worktree, or a `git pull`), and open files' notes are reloaded. Change it with `setup({ reload_interval = 30 })` or `let g:nvim_marks_reload_interval = 30`; `0` turns it off. A save only removes notes this nvim deleted, never ones added elsewhere that it hasn't loaded yet.

Each note has a status: open (new notes, listed under **Notes**), `(⏺)` **TODO**, `(ok)` **DONE** (shown in gray), or `(#)` **Anchors** (just a label on the line). The symbol is shown in front of the note in the list, on its code line and in the editor's top bar; it isn't part of the saved text. The marks window lists notes in one section per status: Notes, TODO, then Tours, Anchors, and DONE at the bottom. Press `@` on a note (in the list, or in the note editor) to move it to the next status (Notes → TODO → Anchors → DONE → Notes); the list redraws with the note in its new section and the cursor still on it, so pressing `@` again keeps cycling the same note. DONE notes are dimmed in the list. If a note's text starts with one of these symbols (from earlier versions, or typed by hand), it's turned into that status and removed from the text.

Notes show at the end of their line, like `local x = 1    -- check this`; a multi-line note is shown on one line, its lines joined by spaces. `:NvimMarksNoteToggle` hides or shows the text on every line (the `*` sign stays, and the notes are still in the panel); `:NvimMarksNoteToggle!` always hides. To start hidden: `setup({ show_note_text = false })` or `let g:nvim_marks_show_note_text = 0`. To show them on their own lines above instead: `setup({ note_style = 'above' })` (or `let g:nvim_marks_note_style = 'above'`). Change the `    -- ` before an inline note with `note_prefix`.


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

For each mark and note, nvim-marks saves an anchor: the row, the line's text, short hashes of the 2 lines above and below, and the commit. While a file is open, Neovim moves marks itself as you edit; matching only runs when a file is opened:

1. The saved row still has the same text: done.
2. Otherwise look for lines with the same text; the one whose surrounding lines match the hashes best wins, then the one closest to the saved row.
3. Otherwise fuzzy-match the text (surrounding lines must match too) within 50 rows of the saved row.
4. Otherwise use the commit saved with it (`"commit"`, HEAD when it was last saved, 12 characters): find the line in the file as it was at that commit, then carry the row through `git diff` to the current file, the way GitHub keeps a PR comment on its line. This finds a line that was rewritten or whose surroundings changed, and follows a file renamed since (the record then moves to the new path). Only for a commit in the current branch's history: a note saved on another branch, or on a commit rebased away, skips this.
5. Otherwise it's an orphan: listed in the marks window under "Not found in this version", kept in the store, and tried again every time the file is opened (e.g. after switching back to the branch where the line exists). Delete it with `-`.

The marks window lists the notes of every file in the repo, the current file's first. `<CR>` opens the file at the note, `o` opens it to edit, `-` deletes it, even for files that aren't open.

As you move the cursor in the marks window, the code window above shows the mark or note under it, with its cursor on that line. It reuses that one window and opens files the normal way (`:edit`), so they're ordinary buffers with git signs, LSP and the rest; a file it opened is closed again when you move to another file, so only one is open at a time. `q` / `Esc` puts the window back on the file you were on; `<CR>` or going to the code window keeps what it shows.

### Data Storage

One JSONL file per repo holds every file's marks and notes, one line each, keyed by the path from the repo root, so `src/a.lua` is the same file in every worktree:

```
~/.local/share/nvim/nvim-marks/
└── your-project-name/
    └── marks.jsonl
```

```json
{"id":"3f9a1c0e","file":"src/a.lua","kind":"note","text":"why?","row":24,"line":"def run(","above":["e3b0c442","e3b0c442"],"below":["2a497258","60b6a494"]}
{"id":"b71d22aa","file":"src/a.lua","kind":"mark","char":"a","row":8,"line":"local x = 1","above":["9f2c41d0"],"below":["77ab01ce"]}
```

A note's `text` is one string (its lines joined with `\n`). New marks and notes are appended; one that's edited or moved rewrites only its own line; a deleted one removes its line. So the file works well in git: every change is a one-line diff. Saving merges into the file (only the current file's lines change), so several nvim instances in different worktrees don't overwrite each other. A `marks-history.json` from the previous format is converted the first time it's read, and left in place.

Every add, update and delete is also appended to `marks-log.jsonl` next to it, with a UTC timestamp, who made it (`nvim <pid>` or another tool), and the whole record before and after, so a note can always be found and put back:

```json
{"ts":"2026-10-20T21:25:17.498Z","op":"update","id":"65532050","file":"src/a.lua","by":"nvim 14830","before":{...},"after":{...}}
```

The log is only ever appended to.

### Performance Considerations

- **Fast startup**: ~1ms initialization time
- **Efficient matching**: exact text lookups first, fuzzy matching only near the saved row, no git calls besides one `rev-parse` per folder
- **Minimal overhead**: No impact on normal editing workflow
