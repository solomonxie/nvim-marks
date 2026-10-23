local M = {}

local anchor = require('nvim-marks.anchor')
local marks_file = require('nvim-marks.marks_file')
local git = require('nvim-marks.git')

M.NS_Signs = vim.api.nvim_create_namespace('nvim-marks.signs')
M.NS_Notes = vim.api.nvim_create_namespace('nvim-marks.notes')
M.NoteTexts = {}  --- @type table<integer, table<integer, string[]>> # {bufnr={mark_id=lines}}
M.NoteStatuses = {}  --- @type table<integer, table<integer, string>> # {bufnr={mark_id=status}}; missing = open
M.LoadedStatuses = {}  --- @type table<integer, table<string, string|false>> # {bufnr={id=status}} as last loaded/saved
M.note_style = vim.g.nvim_marks_note_style or 'inline'  --- @type 'inline'|'above' # set by setup()
M.note_prefix = '    -- '  --- @type string # before an inline note
M.show_note_text = vim.g.nvim_marks_show_note_text ~= 0  --- @type boolean # false: only the `*` sign shows, not the text
M.Orphans = {}  --- @type table<integer, table[]> # {bufnr={record}}, saved marks/notes not found in the buffer's current version
M.RecordIds = {}  --- @type table<integer, table> # {bufnr={marks={char=id}, notes={extmark_id=id}, known={id=true}}}, so a saved record keeps its line in the store
M.OnDisk = {}  --- @type table<integer, table<string, boolean>> # {bufnr={id=true}}: records this buffer loaded or saved
M.LoadedAt = {}  --- @type table<integer, integer> # {bufnr=store mtime when its notes were last loaded or saved}
M.LoadedTexts = {}  --- @type table<integer, table<string, string[]>> # {bufnr={id=text}}, notes as last loaded or saved, to tell our edits from others'

M.LoadedFiles = {}  --- @type table<integer, table<string, string>> # {bufnr={id=file}}: file key as last loaded or saved, to tell a rename of this file from a move elsewhere
local ValidMarkChars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ'

function M.is_real_file(bufnr)
    if type(bufnr) ~= 'number' or not vim.api.nvim_buf_is_valid(bufnr) then
        return false
    end
    local buftype = vim.api.nvim_get_option_value('buftype', {buf=bufnr})
    if buftype ~= '' then
        return false
    end
    local path = vim.api.nvim_buf_get_name(bufnr)
    if path == '' then
        return false
    end
    return vim.fn.filereadable(path) == 1
end

--- @return string, table, string # absolute path (symlinks resolved), repo info, store file
local function locate_store(bufnr)
    local path = vim.fn.resolve(vim.api.nvim_buf_get_name(bufnr))
    local info = marks_file.work_files_repo(path) or git.repo_info(path)
    local store_path = marks_file.store_path(info)
    marks_file.remember_root(store_path, info.top)
    return path, info, store_path
end

--- Absolute path of a file saved in the repo's store, from whichever checkout (or the work-files folder) has it
---
--- @param file string # saved `file`: path from a repo root, or absolute
--- @param bufnr integer # a buffer of the same repo, to know which store it is
--- @return string, boolean # path, whether it exists
function M.resolve_file(file, bufnr)
    if vim.startswith(file, '/') then return file, vim.fn.filereadable(file) == 1 end
    local _, info, store_path = locate_store(bufnr)
    local roots = marks_file.candidate_roots(store_path, info)
    for _, root in ipairs(roots) do
        local path = root .. '/' .. file
        if vim.fn.filereadable(path) == 1 then return path, true end
    end
    return (roots[1] or vim.fn.getcwd()) .. '/' .. file, false
end

--- Get global vimmarks (A-Z) only
---
--- @return table[] # list of vimmark details [{char, row, path, name}, {...}]: absolute path to open, short name to show
function M.scan_global_vimmarks()
    local global_marks = {}
    for _, item in ipairs(vim.fn.getmarklist()) do
        local char = item.mark:sub(2,2)
        local _, row, _, _ = unpack(item.pos)
        if char:match('[A-Z]') ~= nil then
            local path = vim.fn.fnamemodify(item.file, ':p')  -- absolute, so it still opens after a `:cd`
            table.insert(global_marks, {char, row, path, M.display_name(path)})
        end
    end
    return global_marks
end

--- @return string # path from its repo root (e.g. `src/a.lua`), or with `~` outside a repo; never relative to the cwd
function M.display_name(path)
    local info = marks_file.work_files_repo(path) or git.repo_info(path)
    if info.top and vim.startswith(path, info.top .. '/') then return path:sub(#info.top + 2) end
    return vim.fn.fnamemodify(path, ':~')
end

--- Get local vimmarks (a-z) only
---
--- @return table[] # list of vimmark details [{char, row}, {...}]
function M.scan_vimmarks(target_bufnr)
    local vimmarks = {}
    for _, item in ipairs(vim.fn.getmarklist(target_bufnr)) do
        local char = item.mark:sub(2,2)
        local _, row, _, _ = unpack(item.pos)
        if char:match('[a-z]') ~= nil then
            table.insert(vimmarks, {char, row})
        end
    end
    return vimmarks
end

--- Get the A-Z marks placed in this buffer
---
--- @return table[] # [{char, row}, {...}]
local function scan_buffer_global_marks(bufnr)
    local path = vim.fn.resolve(vim.api.nvim_buf_get_name(bufnr))
    local marks = {}
    for _, item in ipairs(vim.fn.getmarklist()) do
        local char = item.mark:sub(2,2)
        if char:match('[A-Z]') ~= nil and vim.fn.resolve(vim.fn.fnamemodify(item.file, ':p')) == path then
            table.insert(marks, {char, item.pos[2]})
        end
    end
    return marks
end

--- @return table # {marks={char=id}, notes={extmark_id=id}} of the buffer
local function ids_of(bufnr)
    if bufnr == 0 then bufnr = vim.api.nvim_get_current_buf() end  -- kept by real bufnr, like note texts
    M.RecordIds[bufnr] = M.RecordIds[bufnr] or {marks={}, notes={}, known={}}
    return M.RecordIds[bufnr]
end

--- Give a mark/note a record id, and remember it so a later save knows it may delete it
local function track(bufnr, id)
    ids_of(bufnr).known[id] = true
    return id
end

--- @return string # `(⏺) `-style symbol for a status, with a trailing space; empty for open notes
function M.status_prefix(status)
    local symbol = marks_file.STATUS_SYMBOLS[status or 'open'] or ''
    return symbol ~= '' and (symbol .. ' ') or ''
end

--- @return string # a note's lines on one line, joined by single spaces; empty lines dropped
function M.one_line(text)
    local parts = {}
    for _, line in ipairs(text) do
        local trimmed = vim.trim(line)
        if trimmed ~= '' then table.insert(parts, trimmed) end
    end
    return table.concat(parts, ' ')
end

--- @param text string[]|string|nil # a note's lines (or one string)
--- @return boolean # true when there's nothing in it but spaces: such a note counts as deleted
function M.is_empty_note(text)
    if type(text) == 'table' then text = table.concat(text, '\n') end
    return vim.trim(text or '') == ''
end

--- Get notes(extmarks) from given buffer
---
--- @return table[] # list of extmark details [{mark_id, row, text, status}, {...}]; status nil = open
function M.scan_notes(bufnr)
    if bufnr == 0 then bufnr = vim.api.nvim_get_current_buf() end  -- Note texts are kept by real bufnr
    local notes = {}
    local items = vim.api.nvim_buf_get_extmarks(bufnr, M.NS_Notes, 0, -1, {})
    for _, ext in ipairs(items) do
        local mark_id, row, _ = unpack(ext)
        local text = (M.NoteTexts[bufnr] or {})[mark_id] or {}
        table.insert(notes, {mark_id, row+1, text, (M.NoteStatuses[bufnr] or {})[mark_id]})
    end
    return notes
end

--- @return string # the status after `status` in the cycle (open → todo → anchor → done → open)
function M.next_status(status)
    local list = marks_file.STATUSES
    for i, s in ipairs(list) do
        if s == (status or 'open') then return list[i % #list + 1] end
    end
    return list[1]
end

--- Set an open buffer's note status and redraw it (its symbol is shown in front of the text)
function M.set_note_status(bufnr, mark_id, status)
    M.NoteStatuses[bufnr] = M.NoteStatuses[bufnr] or {}
    M.NoteStatuses[bufnr][mark_id] = status ~= 'open' and status or nil
    local ext = vim.api.nvim_buf_get_extmark_by_id(bufnr, M.NS_Notes, mark_id, {})
    if ext[1] then
        local opts = M.note_display_opts((M.NoteTexts[bufnr] or {})[mark_id] or {}, status)
        opts.id = mark_id
        vim.api.nvim_buf_set_extmark(bufnr, M.NS_Notes, ext[1], ext[2], opts)
    end
end

--- Create a note extmark
--- 'inline' (default): at the end of the line as `-- note`, a multi-line note on one line, its lines joined by spaces
--- 'above': as its own lines above the line
---
--- @param row integer # 1-indexed
--- @param record_id string|nil # id of the saved record it came from, nil for a new note
--- @return table # extmark options that draw a note: the `*` sign, plus its text unless note text is turned off
local function note_display(text, status)
    local opts = {sign_text='*', sign_hl_group='Comment'}
    if not M.show_note_text then return opts end
    if M.note_style == 'above' then
        opts.virt_lines_above = true
        opts.virt_lines = vim.tbl_map(function(line) return {{line, 'Comment'}} end, text)
        if opts.virt_lines[1] then opts.virt_lines[1][1][1] = M.status_prefix(status) .. opts.virt_lines[1][1][1] end
    else
        opts.virt_text = {{M.note_prefix .. M.status_prefix(status) .. M.one_line(text), 'Comment'}}  -- gray, like a comment
        opts.virt_text_pos = 'eol'
    end
    return opts
end

function M.note_display_opts(text, status) return note_display(text, status) end

--- @param status string|nil # open/todo/anchor/done; nil = open
function M.set_note(bufnr, row, text, record_id, status)
    if bufnr == 0 then bufnr = vim.api.nvim_get_current_buf() end  -- Note texts are kept by real bufnr
    local mark_id = vim.api.nvim_buf_set_extmark(bufnr, M.NS_Notes, row-1, 0, note_display(text, status))  -- extmark is 0-indexed
    M.NoteStatuses[bufnr] = M.NoteStatuses[bufnr] or {}
    M.NoteStatuses[bufnr][mark_id] = status ~= 'open' and status or nil
    -- Shown text is joined for display, keep the original lines for saving and editing
    M.NoteTexts[bufnr] = M.NoteTexts[bufnr] or {}
    M.NoteTexts[bufnr][mark_id] = text
    ids_of(bufnr).notes[mark_id] = track(bufnr, record_id or marks_file.new_id())
    return mark_id
end

--- Show or hide the text of every note in every buffer, keeping the notes themselves (and their `*` signs)
---
--- @param show boolean|nil # nil flips the current setting
--- @return boolean # whether note text is now shown
function M.toggle_note_text(show)
    if show == nil then show = not M.show_note_text end
    M.show_note_text = show
    for bufnr, texts in pairs(M.NoteTexts) do
        if vim.api.nvim_buf_is_valid(bufnr) then
            for _, ext in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, M.NS_Notes, 0, -1, {})) do
                local mark_id, row, col = unpack(ext)
                local opts = note_display(texts[mark_id] or {}, (M.NoteStatuses[bufnr] or {})[mark_id])
                opts.id = mark_id  -- same extmark redrawn, so its record id and position stay
                vim.api.nvim_buf_set_extmark(bufnr, M.NS_Notes, row, col, opts)
            end
        end
    end
    return show
end

--- Scan multiple vimmarks on a given row
---
--- @return string[] #  Signs of Vimmarks
function M.get_mark_chars_by_row(target_bufnr, target_row)
    local markchars = {}
    for i=1, #ValidMarkChars do
        local char = ValidMarkChars:sub(i,i)
        local bufnr, row, _, _ = unpack(vim.fn.getpos("'"..char))
        if bufnr == 0 then bufnr = vim.api.nvim_get_current_buf() end  -- Get real bufnr (0 means current)
        if bufnr == target_bufnr and row == target_row then
            table.insert(markchars, char)
        end
    end
    return markchars
end

--- Create a vimmark
function M.set_vimmark(bufnr, char, row)
    vim.api.nvim_buf_set_mark(bufnr, char, row, 0, {})
    ids_of(bufnr).marks[char] = track(bufnr, marks_file.new_id())  -- a mark set again is a new record
    -- A mark set again replaces its orphan
    M.Orphans[bufnr] = vim.tbl_filter(function(o) return o.char ~= char end, M.Orphans[bufnr] or {})
end

function M.delete_vimmark(bufnr, row)
    local markchars = M.get_mark_chars_by_row(bufnr, row)
    for _, char in ipairs(markchars) do
        vim.api.nvim_buf_del_mark(bufnr, char)
    end
end

function M.delete_note(target_bufnr, target_row)
    local notes = M.scan_notes(target_bufnr)
    for _, item in ipairs(notes) do
        local mark_id, row, _ = unpack(item)
        if row == target_row then
            vim.api.nvim_buf_del_extmark(target_bufnr, M.NS_Notes, mark_id)
        end
    end
end

function M.delete_orphan(bufnr, index)
    table.remove(M.Orphans[bufnr] or {}, index)
end

--- Save this buffer's marks+notes into the repo's store, leaving other files' records alone
function M.save_all(bufnr)
    if bufnr == 0 then bufnr = vim.api.nvim_get_current_buf() end  -- per-buffer state is kept by real bufnr
    if not M.is_real_file(bufnr) or not vim.api.nvim_buf_is_loaded(bufnr) then return end
    if M.Reloading then return end
    -- When nvim reloads a file changed outside (e.g. `git pull`), the buffer is already emptied by then
    -- (BufReadPre): there's nothing to anchor to, and saving would overwrite every anchor with blank lines
    if vim.api.nvim_buf_line_count(bufnr) <= 1 and vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] == '' then return end
    local path, info, store_path = locate_store(bufnr)
    local key = marks_file.file_key(path, info)
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local ids = ids_of(bufnr)
    local commit = git.head_commit(info.top)
    local function record(id, kind, row, extra)
        local a = anchor.make(lines, row)
        return vim.tbl_extend('force', {id=id, file=key, kind=kind, row=a.row, line=a.line, above=a.above, below=a.below, commit=commit}, extra)
    end
    local current = {}
    local marks = M.scan_vimmarks(bufnr)
    vim.list_extend(marks, scan_buffer_global_marks(bufnr))
    for _, item in ipairs(marks) do
        local char, row = unpack(item)
        ids.marks[char] = ids.marks[char] or track(bufnr, marks_file.new_id())  -- set with `:mark`, not through the menu
        table.insert(current, record(ids.marks[char], 'mark', row, {char=char}))
    end
    for _, item in ipairs(M.scan_notes(bufnr)) do
        local mark_id, row, text, status = unpack(item)
        ids.notes[mark_id] = ids.notes[mark_id] or track(bufnr, marks_file.new_id())
        table.insert(current, record(ids.notes[mark_id], 'note', row, {text=text, status=status}))
    end
    vim.list_extend(current, M.Orphans[bufnr] or {})  -- saved as they were
    -- Re-read right before writing, another nvim (e.g. in another worktree) may have saved meanwhile
    for _, orphan in ipairs(M.Orphans[bufnr] or {}) do track(bufnr, orphan.id) end
    M.LoadedTexts[bufnr] = M.LoadedTexts[bufnr] or {}
    M.OnDisk[bufnr] = M.OnDisk[bufnr] or {}
    M.LoadedStatuses[bufnr] = M.LoadedStatuses[bufnr] or {}
    M.LoadedFiles[bufnr] = M.LoadedFiles[bufnr] or {}
    local records, changed = marks_file.merge_file(marks_file.load(store_path), key, current, ids.known, M.LoadedTexts[bufnr],
                                                   M.OnDisk[bufnr], M.LoadedStatuses[bufnr], M.LoadedFiles[bufnr])
    for _, record in ipairs(records) do
        if record.file == key then
            M.OnDisk[bufnr][record.id] = true
            M.LoadedFiles[bufnr][record.id] = key
        end
    end
    for _, item in ipairs(current) do
        if item.kind == 'note' then
            M.LoadedTexts[bufnr][item.id] = item.text
            M.LoadedStatuses[bufnr][item.id] = item.status or false
        end
    end
    if changed then
        marks_file.save(store_path, records)
        M.LoadedAt[bufnr] = marks_file.mtime(store_path)  -- our own write, not a change to reload
    end
    -- What's on disk now (theirs merged with ours) is what this buffer should show: reload it when anything
    -- of theirs was kept, so a later save starts from it instead of from old data
    local disk = {}
    for _, record in ipairs(records) do if record.file == key then disk[record.id] = M.record_key(record) end end
    for _, item in ipairs(current) do
        if disk[item.id] ~= M.record_key(item) then disk.stale = true end
        disk[item.id] = nil
    end
    if disk.stale or next(disk) ~= nil then M.reload_from_store(bufnr) end
end

--- The note's text as saved in the store right now, or nil when it's not there (new, or deleted elsewhere)
---
--- @param note table # from the menu: {bufnr, extmark_id} for an open file, or {store_path, id} for a closed one
function M.latest_note_text(note)
    local id, store_path = note.id, note.store_path
    if note.extmark_id then
        id = (M.RecordIds[note.bufnr] or {notes={}}).notes[note.extmark_id]
        store_path = select(3, locate_store(note.bufnr))
    end
    for _, record in ipairs(marks_file.load(store_path)) do
        if record.id == id then return record.text end
    end
    return nil
end

--- Combine the user's edit with a change made elsewhere while the editor was open
--- If the user only appended lines, append them to the latest text; otherwise the user's full edit wins.
---
--- @param before string[] # text when the editor opened
--- @param latest string[] # text on disk now
--- @param edited string[] # text the user saved
--- @return string[]
function M.merge_note_edit(before, latest, edited)
    if #edited > #before and vim.deep_equal(vim.list_slice(edited, 1, #before), before) then
        local merged = vim.deepcopy(latest)
        vim.list_extend(merged, vim.list_slice(edited, #before + 1))
        return merged
    end
    return edited
end

--- @return string # what of a record a reload would change: kind, mark letter and note text (not the anchor)
function M.record_key(record)
    local text = record.text
    if type(text) == 'table' then text = table.concat(text, '\n') end
    return (record.kind or '') .. '|' .. (record.char or '') .. '|' .. (record.status or 'open') .. '|' .. (text or '')
end

--- Show what's in the store for this buffer now (another nvim or an agent changed it), without saving first
function M.reload_from_store(bufnr)
    M.Reloading = true
    local ok, err = pcall(M.restore_marks, bufnr)
    M.Reloading = false
    if not ok then error(err) end
    M.refresh_sign_bar(bufnr)
end

--- When the anchor isn't found: find the record's line in the file as it was at its `commit`, then carry that row
--- through the diff to the current lines. Finds a line that was rewritten or whose surroundings changed.
--- Only for a commit in HEAD's history; a note saved on another branch stays an orphan.
---
--- @return integer|nil # row in `lines`
function M.relocate_by_commit(info, record, lines)
    if not (record.commit and info.top) or not git.is_ancestor(info.top, record.commit) then return nil end
    local old = git.file_at_commit(info.top, record.commit, record.old_file or record.file)
    if not old then return nil end
    -- The saved row is in that version when the file was saved as committed; else where the anchor is in it
    local old_row = record.row
    if vim.trim(old[old_row] or '') ~= vim.trim(record.line or '') then old_row = anchor.locate(record, old) end
    if not old_row then return nil end
    return anchor.map_row(old, lines, old_row)
end

--- Records of a file that was renamed to `key` since they were saved (their own file is gone from this checkout)
---
--- @return table[] # with `file` set to `key` (saved under it from now on) and `old_file` to read the old version
local function renamed_records(info, key, records)
    local found = {}
    if not info.top then return found end
    for _, record in ipairs(records) do
        if record.commit and record.file ~= key and not vim.startswith(record.file, '/')
            and vim.fn.filereadable(info.top .. '/' .. record.file) == 0
            and git.is_ancestor(info.top, record.commit)
            and git.renames_since(info.top, record.commit)[record.file] == key then
            record.old_file, record.file = record.file, key
            table.insert(found, record)
        end
    end
    return found
end

--- Same for a tour step, from a buffer of the tour's repo
---
--- @return integer|nil
function M.relocate_step(step, bufnr, lines)
    local _, info = locate_store(bufnr)
    return M.relocate_by_commit(info, step, lines)
end

--- @return string, string|nil # folder to list tours from for this buffer, and the worktree name (see marks_file.tours_dir)
function M.tours_dir(bufnr)
    local path, info = locate_store(bufnr)
    return marks_file.tours_dir(path, info)
end

--- @return string|nil # HEAD of the checkout `bufnr` is in, short; nil outside a git repo
function M.head_commit(bufnr)
    local _, info = locate_store(bufnr)
    return git.head_commit(info.top)
end

--- The file as it was at a commit, from a buffer of the same repo. Worktrees share git's objects, so this reads a
--- commit made on any branch or worktree, not only this checkout's history.
---
--- @return string[]|nil # nil when it isn't a git repo, the commit is gone, or the file wasn't in it
function M.file_at_commit(bufnr, commit, file)
    local _, info = locate_store(bufnr)
    if not info.top then return nil end
    return git.file_at_commit(info.top, commit, file)
end

--- Restore marks+notes of a buffer from the repo's store
function M.restore_marks(bufnr)
    if bufnr == 0 then bufnr = vim.api.nvim_get_current_buf() end
    local path, info, store_path = locate_store(bufnr)
    local key = marks_file.file_key(path, info)
    local all = marks_file.load(store_path)
    local records = vim.tbl_filter(function(r) return r.file == key end, all)
    vim.list_extend(records, renamed_records(info, key, all))
    -- Start clean, `:e!` can keep some old note extmarks
    vim.api.nvim_buf_clear_namespace(bufnr, M.NS_Notes, 0, -1)
    M.NoteTexts[bufnr] = {}
    M.NoteStatuses[bufnr] = {}
    M.LoadedStatuses[bufnr] = {}
    M.RecordIds[bufnr] = {marks={}, notes={}, known={}}
    M.Orphans[bufnr] = {}
    M.LoadedTexts[bufnr] = {}
    M.OnDisk[bufnr] = {}
    M.LoadedFiles[bufnr] = {}
    for _, record in ipairs(records) do
        M.OnDisk[bufnr][record.id] = true
        M.LoadedFiles[bufnr][record.id] = record.old_file or record.file  -- a renamed file's records: still its old key on disk
    end
    M.LoadedAt[bufnr] = marks_file.mtime(store_path)
    if #records == 0 then
        local legacy = marks_file.load_legacy(info, key)
        if legacy == nil then return end
        -- Old version saved rows only: restore at those rows as they are
        for _, mark in ipairs(legacy.marks) do pcall(M.set_vimmark, bufnr, mark.char, mark.row) end
        for _, note in ipairs(legacy.notes) do pcall(M.set_note, bufnr, note.row, note.text) end
        return
    end
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local hashes = {}  -- line hashes, shared by all anchors of this file
    for _, record in ipairs(records) do
        local row = anchor.locate(record, lines, hashes) or M.relocate_by_commit(info, record, lines)
        if row == nil and record.kind == 'note' and M.is_empty_note(record.text) then
            track(bufnr, record.id)  -- emptied note whose line is gone too: deleted, not an orphan
        elseif row == nil then
            -- e.g. on another branch: keep it, it's tried again next time the file is opened
            table.insert(M.Orphans[bufnr], record)
            track(bufnr, record.id)
        elseif record.kind == 'mark' then
            vim.api.nvim_buf_set_mark(bufnr, record.char, row, 0, {})
            M.RecordIds[bufnr].marks[record.char] = track(bufnr, record.id)
        elseif M.is_empty_note(record.text) then
            track(bufnr, record.id)  -- emptied (e.g. by an agent or by hand): counts as deleted, dropped on save
        else
            M.set_note(bufnr, row, record.text, record.id, record.status)
            M.LoadedTexts[bufnr][record.id] = record.text
            M.LoadedStatuses[bufnr][record.id] = record.status or false
        end
    end
end

--- Reload the buffer's notes and marks if the store changed on disk since they were loaded
--- (another nvim or a `git pull` wrote it). Unsaved changes here are saved first, so nothing is lost.
---
--- @return boolean # whether it reloaded
function M.reload_if_changed(bufnr)
    if not M.is_real_file(bufnr) or not vim.api.nvim_buf_is_loaded(bufnr) or M.LoadedAt[bufnr] == nil then return false end
    local _, _, store_path = locate_store(bufnr)
    local mtime = marks_file.mtime(store_path)
    if mtime == nil or mtime == M.LoadedAt[bufnr] then return false end
    M.save_all(bufnr)  -- merges our unsaved changes with theirs, then reloads what's on disk
    M.reload_from_store(bufnr)
    return true
end

--- Restore A-Z marks for files not opened yet, so `'A` can jump to them (opt-in: g:nvim_marks_restore_global)
--- The store only holds rows, the anchor is matched when the file is opened
function M.restore_global_marks(bufnr)
    if vim.g.nvim_marks_restore_global ~= 1 then return end
    local _, info, store_path = locate_store(bufnr)
    if not info.top then return end
    for _, record in ipairs(marks_file.load(store_path)) do
        local path, exists = M.resolve_file(record.file, bufnr)
        if record.kind == 'mark' and record.char:match('[A-Z]') and vim.fn.getpos("'" .. record.char)[2] == 0 and exists then
            vim.fn.setpos("'" .. record.char, {vim.fn.bufadd(path), record.row, 1, 0})
        end
    end
end

--- @return string, string # buffer's file key (path from repo root), its repo's store file
function M.buffer_store(bufnr)
    local path, info, store_path = locate_store(bufnr)
    return marks_file.file_key(path, info), store_path
end

--- Change (text and/or status) or delete (neither) a note/mark saved for a file that isn't open
function M.edit_stored(store_path, id, text, status)
    marks_file.edit_record(store_path, id, text, status)
end

--- Every note and mark saved for the repo of `bufnr`, for listing files that aren't open
--- Open buffers have newer info in memory (unsaved additions/deletions), so the caller should prefer those
---
--- @return table[] # records with `path` and `exists` added: [{id, file, path, exists, kind, char, text, row, line}], by file and row
function M.scan_repo_items(bufnr)
    local _, _, store_path = locate_store(bufnr)
    local items = marks_file.load(store_path)
    for _, record in ipairs(items) do
        record.path, record.exists = M.resolve_file(record.file, bufnr)
    end
    table.sort(items, function(a, b)
        if a.file ~= b.file then return a.file < b.file end
        return a.row < b.row
    end)
    return items
end

--- Show a file in a window and reuse that window, with `:edit` (or `:buffer` when it's already open), so it's an
--- ordinary file buffer: filetype, syntax/Treesitter, LSP, git signs and every other BufRead/BufEnter hook run as
--- when you open it yourself. The caller decides whether a file this opened stays open (see M.close_preview_buffer).
--- Call it outside an autocmd (vim.schedule from one): inside a non-nested autocmd those hooks don't run.
---
--- @param win integer # the window to show the file in
--- @param path_or_bufnr string|integer # a file path, or a buffer
--- @return integer|nil, boolean # the buffer shown (nil if it couldn't be opened), and whether this call opened it
---                                (it wasn't loaded before)
function M.show_in_window(win, path_or_bufnr)
    local bufnr = path_or_bufnr
    if type(path_or_bufnr) == 'string' then
        if vim.fn.filereadable(path_or_bufnr) == 0 then return nil, false end
        bufnr = vim.fn.bufnr(path_or_bufnr)  -- already has a buffer: switch to it rather than re-read it with :edit
    end
    if bufnr ~= -1 and not vim.api.nvim_buf_is_valid(bufnr) then return nil, false end
    if bufnr ~= -1 and vim.api.nvim_win_get_buf(win) == bufnr then return bufnr, false end
    local opened = bufnr == -1 or not vim.api.nvim_buf_is_loaded(bufnr)
    local ok, err = pcall(vim.api.nvim_win_call, win, function()
        if bufnr ~= -1 then
            vim.cmd('keepjumps buffer ' .. bufnr)
        else
            vim.cmd('keepjumps edit ' .. vim.fn.fnameescape(path_or_bufnr))
        end
    end)
    if not ok then
        vim.api.nvim_echo({{'nvim-marks: ' .. tostring(err), 'ErrorMsg'}}, false, {})
        return nil, false
    end
    return vim.api.nvim_win_get_buf(win), opened
end

--- Close a file buffer the tour or the menu preview opened, once it has moved on to another file, so previewing
--- doesn't leave a buffer per file behind. Kept if it has unsaved changes or is shown in a window.
function M.close_preview_buffer(bufnr)
    if not (bufnr and vim.api.nvim_buf_is_loaded(bufnr)) then return end
    if vim.bo[bufnr].modified or #vim.fn.win_findbuf(bufnr) > 0 then return end
    vim.api.nvim_buf_delete(bufnr, {})
end

--- @return integer # display width of text as the window shows it: `code` backticks take no room when they're
---                   concealed (the user's markdown setup hides them with conceallevel >= 2)
local function shown_width(text, concealed)
    local width = vim.fn.strdisplaywidth(text)
    if not concealed then return width end
    local _, spans = text:gsub('`[^`]+`', '')
    return width - 2 * spans
end

--- Line up the columns of markdown tables on screen: each cell is padded, as inline virtual text, to the widest cell
--- of its column (as shown: without `code` backticks when the window conceals them), so the text itself (what's
--- saved) stays as typed. A table is a run of lines starting with `|`; its `|---|---|` row is padded with dashes.
--- Redraw after every change (it clears the namespace first).
---
--- @param ns integer # namespace for the padding
function M.align_tables(bufnr, ns)
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local win = vim.fn.bufwinid(bufnr)
    local concealed = win ~= -1 and vim.wo[win].conceallevel >= 2
    local function cells(line)  -- {start byte, end byte (the cell's text, without the bars)} for each cell
        local out, pos = {}, line:find('|', 1, true) + 1
        while pos <= #line do
            local bar = line:find('|', pos, true)
            -- a `|` inside `code` doesn't end the cell
            while bar do
                local _, ticks = line:sub(1, bar):gsub('`', '')
                if ticks % 2 == 0 then break end
                bar = line:find('|', bar + 1, true)
            end
            table.insert(out, {pos, (bar or #line + 1) - 1})
            if not bar then break end
            pos = bar + 1
        end
        if out[#out] and vim.trim(line:sub(out[#out][1], out[#out][2])) == '' and line:match('|%s*$') then
            table.remove(out)  -- the empty space after the closing bar
        end
        return out
    end
    local row = 1
    while row <= #lines do
        if not lines[row]:match('^%s*|') then
            row = row + 1
        else
            local first = row
            while row <= #lines and lines[row]:match('^%s*|') do row = row + 1 end
            local rows, widths = {}, {}
            for r = first, row - 1 do
                local c = cells(lines[r])
                local is_rule = lines[r]:match('^%s*|[%s|:%-]+$') ~= nil
                rows[r] = {cells=c, rule=is_rule}
                if not is_rule then
                    for k, cell in ipairs(c) do
                        local w = shown_width(vim.trim(lines[r]:sub(cell[1], cell[2])), concealed)
                        widths[k] = math.max(widths[k] or 0, w)
                    end
                end
            end
            for r = first, row - 1 do
                for k, cell in ipairs(rows[r].cells) do
                    local text = lines[r]:sub(cell[1], cell[2])
                    local target = (widths[k] or 0) + 2  -- one space each side, like `| text |`
                    local pad = target - shown_width(text, concealed)
                    if pad > 0 then
                        local fill = rows[r].rule and string.rep('-', pad) or string.rep(' ', pad)
                        vim.api.nvim_buf_set_extmark(bufnr, ns, r - 1, cell[2], {
                            virt_text={{fill, rows[r].rule and 'Comment' or 'Normal'}}, virt_text_pos='inline',
                        })
                    end
                end
            end
        end
    end
end

--- @return string # the buffer's line at row, trimmed, for previews
function M.line_preview(bufnr, row)
    if not vim.api.nvim_buf_is_loaded(bufnr) then return '' end
    local line = vim.api.nvim_buf_get_lines(bufnr, row-1, row, false)[1] or ''
    return vim.trim(line)
end


--- Scan latest vimmarks and update left sign bar
--- Don't use vim native signs like `sign_define/sign_place` because neovim will create extmarks anyways
function M.refresh_sign_bar(bufnr)
    if bufnr == 0 then bufnr = vim.api.nvim_get_current_buf() end  -- Get real bufnr (0 means current)
    vim.api.nvim_buf_clear_namespace(bufnr, M.NS_Signs, 0, -1)  -- Delete all signs then add each
    local marks = M.scan_vimmarks(bufnr)
    vim.list_extend(marks, scan_buffer_global_marks(bufnr))
    for _, item in ipairs(marks) do
        local char, row = unpack(item)
        vim.api.nvim_buf_set_extmark(bufnr, M.NS_Signs, row-1, 0, {  -- extmark is 0-indexed
            sign_text=char,
            sign_hl_group='WarningMsg',
        })
    end
    -- Notes:
    -- No need, they are extmarks and will display signs already on creation
end

return M
