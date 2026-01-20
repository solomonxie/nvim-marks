# nvim-marks

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Neovim](https://img.shields.io/badge/Neovim-0.5%2B-blue.svg)](https://neovim.io/)

Persistent marks and annotations for Neovim that survive code changes, branch switches, and file moves.

## ✨ Features

- [x] **Persistent Marks**: Marks that survive across sessions, branch switches, and code changes
- [x] **Smart Matching**: Intelligent position restoration using git blame, line content, and surrounding context
- [x] **Project-Scoped**: Storage organized per project in `.git/persistent_marks/`
- [x] **Dual Support**: Works with both Vim marks (a-z, A-Z) and Extmarks for annotations
- [x] **Visual Indicators**: Sign column shows all marks and notes at a glance
- [x] **Automatic**: Save/restore marks automatically on buffer events
- [ ] Smart match each mark on restoring each buffer
- [ ] Match marks after file renamed

<img width="936" height="607" alt="Xnip2026-01-20_10-26-32" src="https://github.com/user-attachments/assets/0f1b306a-e61c-42a3-be61-33a4bb9ec3ac" />


## 📋 Requirements

- **Neovim** 0.5+ (for extmarks support)
- **Git** repository (for smart matching features)

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
2. **Add Mark**: Press any letter `a-z` in the marks window
3. **Add Note**: Press `+` to add an annotation
4. **Delete Mark/Note**: Press `-` to remove marks/notes
5. **Quit**: Press `q` to close the marks window

## 📖 Usage

### Basic Workflow

```vim
" Open marks management window
m

" In the marks window:
" Press a-z     - Add a local mark at current line
" Press A-Z     - Add a global mark at current line
" Press +       - Add a note/annotation
" Press -       - Delete mark/note at current line
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

The plugin works out of the box.
Customizations are to be done.


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

Nvim-marks uses a combination of strategies to ensure marks are "persistent-ish". It does not pursue 100% accuracy which could make it very slow and complex, but it tries to cover most common scenarios and be smart enough to handle most day-to-day cases.

The plugin collects this information for each mark:

- **File path** (relative to project root)
- **Line number**
- **Line content**
- **Surrounding lines content**
- **Git blame info** (commit hash, author, date, etc)

When restoring a mark, nvim-marks tries to match each piece of information with weights and calculates the most confident position to restore the mark. If the overall confidence is low, it will still keep the mark showing in the Mark List but without an associated line number, so that the user can manually link it to a line whenever needed.

### Data Storage

Marks are stored in JSON files based on your customization. By default it's under your project's `.git/persistent_marks/` directory:

```
.git/persistent_marks/
├── your-project-name/
│   ├── src__main__lua.json
│   └── vimmarks_global.json
```

Each file contains:
- **Local marks/notes** (`vimmarks` and `notes`)
- **Global marks** (`vimmarks_global`): Cross-file marks A-Z

### Performance Considerations

- **Fast startup**: ~1ms initialization time
- **Efficient matching**: Uses cached git blame information
- **Minimal overhead**: No impact on normal editing workflow
