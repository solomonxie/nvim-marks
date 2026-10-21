local M = {}

local anchor = require('nvim-marks.anchor')
local store = require('nvim-marks.store')

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
    local info = store.work_files_repo(path) or store.repo_info(path)
    local store_path = store.store_path(info)
    store.remember_root(store_path, info.top)
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
    local roots = store.candidate_roots(store_path, info)
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
    local info = store.work_files_repo(path) or store.repo_info(path)
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
    local symbol = store.STATUS_SYMBOLS[status or 'open'] or ''
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
    local list = store.STATUSES
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
    ids_of(bufnr).notes[mark_id] = track(bufnr, record_id or store.new_id())
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
    ids_of(bufnr).marks[char] = track(bufnr, store.new_id())  -- a mark set again is a new record
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
    local key = store.file_key(path, info)
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local ids = ids_of(bufnr)
    local function record(id, kind, row, extra)
        local a = anchor.make(lines, row)
        return vim.tbl_extend('force', {id=id, file=key, kind=kind, row=a.row, line=a.line, above=a.above, below=a.below}, extra)
    end
    local current = {}
    local marks = M.scan_vimmarks(bufnr)
    vim.list_extend(marks, scan_buffer_global_marks(bufnr))
    for _, item in ipairs(marks) do
        local char, row = unpack(item)
        ids.marks[char] = ids.marks[char] or track(bufnr, store.new_id())  -- set with `:mark`, not through the menu
        table.insert(current, record(ids.marks[char], 'mark', row, {char=char}))
    end
    for _, item in ipairs(M.scan_notes(bufnr)) do
        local mark_id, row, text, status = unpack(item)
        ids.notes[mark_id] = ids.notes[mark_id] or track(bufnr, store.new_id())
        table.insert(current, record(ids.notes[mark_id], 'note', row, {text=text, status=status}))
    end
    vim.list_extend(current, M.Orphans[bufnr] or {})  -- saved as they were
    -- Re-read right before writing, another nvim (e.g. in another worktree) may have saved meanwhile
    for _, orphan in ipairs(M.Orphans[bufnr] or {}) do track(bufnr, orphan.id) end
    M.LoadedTexts[bufnr] = M.LoadedTexts[bufnr] or {}
    M.OnDisk[bufnr] = M.OnDisk[bufnr] or {}
    M.LoadedStatuses[bufnr] = M.LoadedStatuses[bufnr] or {}
    local records, changed = store.merge_file(store.load(store_path), key, current, ids.known, M.LoadedTexts[bufnr], M.OnDisk[bufnr], M.LoadedStatuses[bufnr])
    for _, record in ipairs(records) do
        if record.file == key then M.OnDisk[bufnr][record.id] = true end
    end
    for _, item in ipairs(current) do
        if item.kind == 'note' then
            M.LoadedTexts[bufnr][item.id] = item.text
            M.LoadedStatuses[bufnr][item.id] = item.status or false
        end
    end
    if changed then
        store.save(store_path, records)
        M.LoadedAt[bufnr] = store.mtime(store_path)  -- our own write, not a change to reload
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
    for _, record in ipairs(store.load(store_path)) do
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

--- Restore marks+notes of a buffer from the repo's store
function M.restore_marks(bufnr)
    if bufnr == 0 then bufnr = vim.api.nvim_get_current_buf() end
    local path, info, store_path = locate_store(bufnr)
    local key = store.file_key(path, info)
    local records = vim.tbl_filter(function(r) return r.file == key end, store.load(store_path))
    -- Start clean, `:e!` can keep some old note extmarks
    vim.api.nvim_buf_clear_namespace(bufnr, M.NS_Notes, 0, -1)
    M.NoteTexts[bufnr] = {}
    M.NoteStatuses[bufnr] = {}
    M.LoadedStatuses[bufnr] = {}
    M.RecordIds[bufnr] = {marks={}, notes={}, known={}}
    M.Orphans[bufnr] = {}
    M.LoadedTexts[bufnr] = {}
    M.OnDisk[bufnr] = {}
    for _, record in ipairs(records) do M.OnDisk[bufnr][record.id] = true end
    M.LoadedAt[bufnr] = store.mtime(store_path)
    if #records == 0 then
        local legacy = store.load_legacy(info, key)
        if legacy == nil then return end
        -- Old version saved rows only: restore at those rows as they are
        for _, mark in ipairs(legacy.marks) do pcall(M.set_vimmark, bufnr, mark.char, mark.row) end
        for _, note in ipairs(legacy.notes) do pcall(M.set_note, bufnr, note.row, note.text) end
        return
    end
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local hashes = {}  -- line hashes, shared by all anchors of this file
    for _, record in ipairs(records) do
        local row = anchor.locate(record, lines, hashes)
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
    local mtime = store.mtime(store_path)
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
    for _, record in ipairs(store.load(store_path)) do
        local path, exists = M.resolve_file(record.file, bufnr)
        if record.kind == 'mark' and record.char:match('[A-Z]') and vim.fn.getpos("'" .. record.char)[2] == 0 and exists then
            vim.fn.setpos("'" .. record.char, {vim.fn.bufadd(path), record.row, 1, 0})
        end
    end
end

--- @return string, string # buffer's file key (path from repo root), its repo's store file
function M.buffer_store(bufnr)
    local path, info, store_path = locate_store(bufnr)
    return store.file_key(path, info), store_path
end

--- Change (text and/or status) or delete (neither) a note/mark saved for a file that isn't open
function M.edit_stored(store_path, id, text, status)
    store.edit_record(store_path, id, text, status)
end

--- Every note and mark saved for the repo of `bufnr`, for listing files that aren't open
--- Open buffers have newer info in memory (unsaved additions/deletions), so the caller should prefer those
---
--- @return table[] # records with `path` and `exists` added: [{id, file, path, exists, kind, char, text, row, line}], by file and row
function M.scan_repo_items(bufnr)
    local _, _, store_path = locate_store(bufnr)
    local items = store.load(store_path)
    for _, record in ipairs(items) do
        record.path, record.exists = M.resolve_file(record.file, bufnr)
    end
    table.sort(items, function(a, b)
        if a.file ~= b.file then return a.file < b.file end
        return a.row < b.row
    end)
    return items
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


--- Tests: `nvim -l tests/run.lua`
local function read_fixture(name)
    local dir = vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2)) .. '/../../tests/fixtures/'
    return vim.fn.readfile(dir .. name)
end

local function eq(actual, expected, msg)
    assert(vim.deep_equal(actual, expected), string.format('%s: expected %s, got %s', msg, vim.inspect(expected), vim.inspect(actual)))
end

--- Save marks on v1, switch the file to v2 (like changing branch) and back, marks follow the lines
function M.test_save_restore_across_versions()
    local tmp_dir = vim.fn.tempname()
    vim.fn.mkdir(tmp_dir, 'p')
    store.dir_option = tmp_dir
    local path = tmp_dir .. '/f.lua'
    vim.fn.writefile(read_fixture('v1.lua'), path)
    local bufnr = vim.fn.bufadd(path)
    vim.fn.bufload(bufnr)
    M.set_vimmark(bufnr, 'a', 8)  -- local function save(data)
    M.set_vimmark(bufnr, 'b', 3)  -- local DEBUG = ..., deleted in v2
    M.set_note(bufnr, 10, {'check path'})  -- print('saving', path)
    M.save_all(bufnr)
    local function reopen(fixture)
        vim.api.nvim_buf_delete(bufnr, {force=true})
        vim.fn.writefile(read_fixture(fixture), path)
        bufnr = vim.fn.bufadd(path)
        vim.fn.bufload(bufnr)
        M.restore_marks(bufnr)
    end
    reopen('v2.lua')
    eq(vim.api.nvim_buf_get_mark(bufnr, 'a')[1], 11, 'mark follows the line')
    eq(vim.api.nvim_buf_get_mark(bufnr, 'b')[1], 0, 'mark on deleted line not placed')
    eq(M.Orphans[bufnr][1].char, 'b', 'mark on deleted line kept as orphan')
    eq(M.scan_notes(bufnr)[1][2], 13, 'note follows the edited line')
    eq(M.scan_notes(bufnr)[1][3], {'check path'}, 'note text kept')
    M.save_all(bufnr)
    reopen('v1.lua')
    eq(vim.api.nvim_buf_get_mark(bufnr, 'b')[1], 3, 'orphan comes back with its line')
    eq(vim.api.nvim_buf_get_mark(bufnr, 'a')[1], 8, 'mark back on v1')
    eq(M.scan_notes(bufnr)[1][2], 10, 'note back on v1, no drift')
    vim.api.nvim_buf_delete(bufnr, {force=true})
    store.dir_option = nil
    vim.fn.delete(tmp_dir, 'rf')
end

--- In the JSONL store a new note is one appended line, and a note that moved rewrites only its own line
function M.test_store_lines_change_one_at_a_time()
    local tmp_dir = vim.fn.tempname()
    vim.fn.mkdir(tmp_dir, 'p')
    store.dir_option = tmp_dir
    local path = tmp_dir .. '/f.lua'
    vim.fn.writefile(read_fixture('v1.lua'), path)
    local store_path = tmp_dir .. '/_no_repo/' .. store.FILE_NAME
    local bufnr = vim.fn.bufadd(path)
    vim.fn.bufload(bufnr)
    M.set_note(bufnr, 8, {'first'})
    M.save_all(bufnr)
    local before = vim.fn.readfile(store_path)
    M.set_note(bufnr, 14, {'second'})
    M.save_all(bufnr)
    local after = vim.fn.readfile(store_path)
    eq(#after, 2, 'appended')
    eq(after[1], before[1], 'first note line untouched')
    -- reopen on v2: `first` moves from row 8 to 11, `second` from 14 to 17
    vim.api.nvim_buf_delete(bufnr, {force=true})
    vim.fn.writefile(read_fixture('v2.lua'), path)
    bufnr = vim.fn.bufadd(path)
    vim.fn.bufload(bufnr)
    M.restore_marks(bufnr)
    M.save_all(bufnr)
    local moved = vim.fn.readfile(store_path)
    eq(#moved, 2, 'still one line per note')
    eq(vim.json.decode(moved[1]).id, vim.json.decode(after[1]).id, 'same record kept its place')
    eq(vim.json.decode(moved[1]).row, 11, 'row updated in place')
    vim.api.nvim_buf_delete(bufnr, {force=true})
    store.dir_option = nil
    vim.fn.delete(tmp_dir, 'rf')
end

--- A file changed outside nvim (e.g. `git pull`) and reloaded: notes follow their lines, the saved anchors aren't blanked
function M.test_outside_change_reload()
    local tmp_dir = vim.fn.tempname()
    vim.fn.mkdir(tmp_dir, 'p')
    store.dir_option = tmp_dir
    local path = tmp_dir .. '/f.lua'
    vim.fn.writefile(read_fixture('v1.lua'), path)
    vim.cmd('runtime plugin/nvim-marks.vim')  -- the autocmd that restores notes after a reload
    vim.cmd('edit ' .. path)
    local bufnr = vim.api.nvim_get_current_buf()
    M.set_note(bufnr, 8, {'save'})  -- local function save(data)
    M.save_all(bufnr)
    vim.o.autoread = true
    vim.fn.writefile(read_fixture('v2.lua'), path)  -- 3 lines inserted above it
    vim.uv.fs_utime(path, os.time() + 5, os.time() + 5)  -- make sure nvim sees a newer file
    vim.cmd('checktime')
    eq(vim.api.nvim_buf_get_lines(bufnr, 10, 11, false)[1], 'local function save(data)', 'buffer reloaded from disk')
    eq(M.scan_notes(bufnr)[1][2], 11, 'note moved with its line')
    local saved = store.load(tmp_dir .. '/_no_repo/' .. store.FILE_NAME)[1]
    eq(saved.line, 'local function save(data)', 'saved anchor not blanked by the reload')
    vim.cmd('bwipeout!')
    store.dir_option = nil
    vim.fn.delete(tmp_dir, 'rf')
end

--- Saving twice (e.g. `save_all(0)`, then leaving the buffer) keeps one line per note in the store
function M.test_save_twice_no_duplicates()
    local tmp_dir = vim.fn.tempname()
    vim.fn.mkdir(tmp_dir, 'p')
    store.dir_option = tmp_dir
    local path = tmp_dir .. '/f.lua'
    vim.fn.writefile(read_fixture('v1.lua'), path)
    vim.cmd('edit ' .. path)
    local bufnr = vim.api.nvim_get_current_buf()
    M.set_note(0, 8, {'once'})
    M.save_all(0)
    M.save_all(bufnr)
    eq(#vim.fn.readfile(tmp_dir .. '/_no_repo/' .. store.FILE_NAME), 1, 'one record')
    vim.cmd('bwipeout!')
    store.dir_option = nil
    vim.fn.delete(tmp_dir, 'rf')
end

function M.test_toggle_note_text()
    local bufnr = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, read_fixture('v1.lua'))
    M.set_note(bufnr, 8, {'a note'})
    local function shown() return vim.api.nvim_buf_get_extmarks(bufnr, M.NS_Notes, 0, -1, {details=true})[1][4].virt_text ~= nil end
    eq(shown(), true, 'shown by default')
    M.toggle_note_text()
    eq(shown(), false, 'hidden')
    eq(M.scan_notes(bufnr)[1][3], {'a note'}, 'note kept with its text')
    eq(M.scan_notes(bufnr)[1][2], 8, 'note kept on its line')
    M.toggle_note_text()
    eq(shown(), true, 'shown again')
    vim.api.nvim_buf_delete(bufnr, {force=true})
end

function M.test_merge_note_edit()
    local before = {'why?'}
    local latest = {'(⏺) why?', '--', 'Bot reply:', 'because'}
    eq(M.merge_note_edit(before, latest, {'why?', '-- and how?'}), {'(⏺) why?', '--', 'Bot reply:', 'because', '-- and how?'},
       'appended line goes after the reply written meanwhile')
    eq(M.merge_note_edit(before, latest, {'why not?'}), {'why not?'}, 'a rewrite wins')
end

--- An agent edits the store while nvim has the file open: nvim's next save keeps the agent's reply, its deletion
--- and its new note, and the buffer then shows them
function M.test_save_keeps_changes_made_elsewhere()
    local tmp_dir = vim.fn.tempname()
    vim.fn.mkdir(tmp_dir, 'p')
    store.dir_option = tmp_dir
    local path = tmp_dir .. '/f.lua'
    local store_path = tmp_dir .. '/_no_repo/' .. store.FILE_NAME
    vim.fn.writefile(read_fixture('v1.lua'), path)
    vim.cmd('edit ' .. path)
    local bufnr = vim.api.nvim_get_current_buf()
    M.set_note(bufnr, 8, {'question A'})
    M.set_note(bufnr, 10, {'question B'})
    M.save_all(bufnr)
    vim.uv.sleep(5)  -- a later mtime for the agent's write
    -- the agent: replies to A, deletes B, adds C (like the marks skill does: rewrite the file)
    local records = store.load(store_path)
    local a = vim.tbl_filter(function(r) return r.text[1] == 'question A' end, records)[1]
    a.status = 'todo'
    a.text = {'question A', '--', 'Bot reply:', 'answer'}
    local new = {id='agent001', file=a.file, kind='note', text={'from agent'}, row=3, line=a.line, above={}, below={}}
    store.save(store_path, {a, new})
    M.save_all(bufnr)
    local texts = vim.tbl_map(function(r) return r.text[1] end, store.load(store_path))
    eq(texts, {'question A', 'from agent'}, 'reply kept, deletion kept, new note kept')
    eq(store.load(store_path)[1].status, 'todo', 'status set elsewhere kept')
    local shown = vim.tbl_map(function(n) return n[3][1] end, M.scan_notes(bufnr))
    table.sort(shown)
    eq(shown, {'from agent', 'question A'}, 'buffer shows the latest')
    vim.cmd('bwipeout!')
    store.dir_option = nil
    vim.fn.delete(tmp_dir, 'rf')
end

--- A note emptied to nothing or only spaces (in the editor, by an agent or by hand) counts as deleted
function M.test_empty_note_is_deleted()
    eq(M.is_empty_note({'', '   ', '\t'}), true, 'spaces only')
    eq(M.is_empty_note('  \n '), true, 'one string')
    eq(M.is_empty_note({'', 'x'}), false, 'has text')
    local tmp_dir = vim.fn.tempname()
    vim.fn.mkdir(tmp_dir, 'p')
    store.dir_option = tmp_dir
    local path = tmp_dir .. '/f.lua'
    local store_path = tmp_dir .. '/_no_repo/' .. store.FILE_NAME
    vim.fn.writefile(read_fixture('v1.lua'), path)
    vim.cmd('edit ' .. path)
    local bufnr = vim.api.nvim_get_current_buf()
    M.set_note(bufnr, 8, {'keep'})
    M.set_note(bufnr, 10, {'to empty'})
    M.save_all(bufnr)
    -- emptied in the file (by an agent or by hand)
    local records = store.load(store_path)
    for _, r in ipairs(records) do if r.text[1] == 'to empty' then r.text = {'  ', ''} end end
    store.save(store_path, records)
    M.restore_marks(bufnr)
    eq(#M.scan_notes(bufnr), 1, 'empty note not shown')
    M.save_all(bufnr)
    eq(vim.tbl_map(function(r) return r.text[1] end, store.load(store_path)), {'keep'}, 'empty note removed from the file')
    vim.cmd('bwipeout!')
    store.dir_option = nil
    vim.fn.delete(tmp_dir, 'rf')
end

function M.test_one_line()
    eq(M.one_line({'(⏺) why?', '--', '', 'Bot reply:', '  because  '}), '(⏺) why? -- Bot reply: because', 'spaces, no blanks')
    eq(M.one_line({'one'}), 'one', 'single line')
end

function M.test_status_prefix_on_code_line()
    local bufnr = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, read_fixture('v1.lua'))
    local open_id = M.set_note(bufnr, 3, {'still a question'})
    local todo_id = M.set_note(bufnr, 8, {'why?', '--', 'Bot reply:', 'because'}, nil, 'todo')
    local function shown(id) return vim.api.nvim_buf_get_extmark_by_id(bufnr, M.NS_Notes, id, {details=true})[3].virt_text[1][1] end
    eq(shown(open_id), M.note_prefix .. 'still a question', 'open: no symbol')
    eq(shown(todo_id), M.note_prefix .. '(⏺) why? -- Bot reply: because', 'todo: symbol in front')
    eq(M.NoteTexts[bufnr][todo_id][1], 'why?', 'symbol not in the saved text')
    M.set_note_status(bufnr, open_id, 'done')
    eq(shown(open_id), M.note_prefix .. '(ok) still a question', 'symbol follows a status change')
    vim.api.nvim_buf_delete(bufnr, {force=true})
end

return M
