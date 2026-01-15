# nvim-marks

Persistent marks and annotations built on top of existing Marks(Vim) and Extmarks(NeoVim).

It makes sure all the marks and important annotations to code will be saved to a file under project scope.

It's smart enough to match positions in case of any change.


## Why persistent marks?

When working on large codebases, it's common to have important annotations, bookmarks, or marks that help navigate and understand the code.
However, these marks can be lost when switching branches, pulling updates, or making changes to the code.
Persistent marks ensure that these important references are saved and can be restored even after significant changes to the codebase.

I have been looking for a plugin for this feature for awhile, but none of the plugins I found can make it really "persistent".

## Why persistent marks are so hard?

If we want to put a mark on a line, we need to first know which line it is.
But line number changes so often, and even the line content may change too.
So we need an "anchor" to locate associate the mark with the line which can survive:
- line number changes
- line content changes
- file moves/renames
- branch switches
- edits outside of the editor
- ...

To satisfy all these requirements is really hard. I guess that's why it's so hard to find a good plugin for this feature.

## How nvim-marks works?

Nvim-marks uses a combination of strategies to ensure marks are "persistent-ish", it does not persue 100% accuracy which could make it very slow and complex, but it tries to cover most common scenarios and be smart-enough that can handle most day to day cases.

Nvim-marks tries to collect these information:
- File path (relative to project root)
- Line number
- Line content
- Surrounding lines content
- Git blame info (commit hash, author, date, etc)

When restoring a mark, nvim-marks will try to match each these information with weights, and calculate the most confident position to restore the mark.
If the overall confidence is low, it will still keep the mark showing in the Mark List but without associated line number, so that user can manually link it to a line whenever needed.
