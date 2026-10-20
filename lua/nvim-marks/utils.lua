local M = {}

local anchor = require('nvim-marks.anchor')
local store = require('nvim-marks.store')

M.NS_Signs = vim.api.nvim_create_namespace('nvim-marks.signs')
M.NS_Notes = vim.api.nvim_create_namespace('nvim-marks.notes')
M.NoteTexts = {}  --- @type table<integer, table<integer, string[]>> # {bufnr={mark_id=lines}}
M.note_style = vim.g.nvim_marks_note_style or 'inline'  --- @type 'inline'|'above' # set by setup()
M.note_prefix = '    -- '  --- @type string # before an inline note
M.Orphans = {}  --- @type table<integer, table[]> # {bufnr={record}}, saved marks/notes not found in the buffer's current version
M.RecordIds = {}  --- @type table<integer, table> # {bufnr={marks={char=id}, notes={extmark_id=id}, known={id=true}}}, so a saved record keeps its line in the store
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
    return path, info, store.store_path(info)
end

--- Get global vimmarks (A-Z) only
---
--- @return table[] # list of vimmark details [{char, row, filename}, {...}]
function M.scan_global_vimmarks()
    local global_marks = {}
    for _, item in ipairs(vim.fn.getmarklist()) do
        local char = item.mark:sub(2,2)
        local _, row, _, _ = unpack(item.pos)
        if char:match('[A-Z]') ~= nil then
            table.insert(global_marks, {char, row, vim.fn.fnamemodify(item.file, ':.')})
        end
    end
    return global_marks
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
    M.RecordIds[bufnr] = M.RecordIds[bufnr] or {marks={}, notes={}, known={}}
    return M.RecordIds[bufnr]
end

--- Give a mark/note a record id, and remember it so a later save knows it may delete it
local function track(bufnr, id)
    ids_of(bufnr).known[id] = true
    return id
end

--- Get notes(extmarks) from given buffer
---
--- @return table[] # list of extmark details [{mark_id, row, text}, {...}]
function M.scan_notes(bufnr)
    if bufnr == 0 then bufnr = vim.api.nvim_get_current_buf() end  -- Note texts are kept by real bufnr
    local notes = {}
    local items = vim.api.nvim_buf_get_extmarks(bufnr, M.NS_Notes, 0, -1, {})
    for _, ext in ipairs(items) do
        local mark_id, row, _ = unpack(ext)
        local text = (M.NoteTexts[bufnr] or {})[mark_id] or {}
        table.insert(notes, {mark_id, row+1, text})
    end
    return notes
end

--- Create a note extmark
--- 'inline' (default): at the end of the line as `-- note`, lines of a multi-line note joined with ` | `
--- 'above': as its own lines above the line
---
--- @param row integer # 1-indexed
--- @param record_id string|nil # id of the saved record it came from, nil for a new note
function M.set_note(bufnr, row, text, record_id)
    if bufnr == 0 then bufnr = vim.api.nvim_get_current_buf() end  -- Note texts are kept by real bufnr
    local opts = {sign_text='*', sign_hl_group='Comment'}
    if M.note_style == 'above' then
        opts.virt_lines_above = true
        opts.virt_lines = vim.tbl_map(function(line) return {{line, 'Comment'}} end, text)
    else
        opts.virt_text = {{M.note_prefix .. table.concat(text, ' | '), 'Comment'}}
        opts.virt_text_pos = 'eol'
    end
    local mark_id = vim.api.nvim_buf_set_extmark(bufnr, M.NS_Notes, row-1, 0, opts)  -- extmark is 0-indexed
    -- Shown text is joined for display, keep the original lines for saving and editing
    M.NoteTexts[bufnr] = M.NoteTexts[bufnr] or {}
    M.NoteTexts[bufnr][mark_id] = text
    ids_of(bufnr).notes[mark_id] = track(bufnr, record_id or store.new_id())
    return mark_id
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
    if not M.is_real_file(bufnr) or not vim.api.nvim_buf_is_loaded(bufnr) then return end
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
        local mark_id, row, text = unpack(item)
        ids.notes[mark_id] = ids.notes[mark_id] or track(bufnr, store.new_id())
        table.insert(current, record(ids.notes[mark_id], 'note', row, {text=text}))
    end
    vim.list_extend(current, M.Orphans[bufnr] or {})  -- saved as they were
    -- Re-read right before writing, another nvim (e.g. in another worktree) may have saved meanwhile
    for _, orphan in ipairs(M.Orphans[bufnr] or {}) do track(bufnr, orphan.id) end
    M.LoadedTexts[bufnr] = M.LoadedTexts[bufnr] or {}
    local records, changed = store.merge_file(store.load(store_path), key, current, ids.known, M.LoadedTexts[bufnr])
    for _, item in ipairs(current) do
        if item.kind == 'note' then M.LoadedTexts[bufnr][item.id] = item.text end
    end
    if changed then
        store.save(store_path, records)
        M.LoadedAt[bufnr] = store.mtime(store_path)  -- our own write, not a change to reload
    end
end

--- Restore marks+notes of a buffer from the repo's store
function M.restore_marks(bufnr)
    local path, info, store_path = locate_store(bufnr)
    local key = store.file_key(path, info)
    local records = vim.tbl_filter(function(r) return r.file == key end, store.load(store_path))
    -- Start clean, `:e!` can keep some old note extmarks
    vim.api.nvim_buf_clear_namespace(bufnr, M.NS_Notes, 0, -1)
    M.NoteTexts[bufnr] = {}
    M.RecordIds[bufnr] = {marks={}, notes={}, known={}}
    M.Orphans[bufnr] = {}
    M.LoadedTexts[bufnr] = {}
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
        if row == nil then
            -- e.g. on another branch: keep it, it's tried again next time the file is opened
            table.insert(M.Orphans[bufnr], record)
            track(bufnr, record.id)
        elseif record.kind == 'mark' then
            vim.api.nvim_buf_set_mark(bufnr, record.char, row, 0, {})
            M.RecordIds[bufnr].marks[record.char] = track(bufnr, record.id)
        else
            M.set_note(bufnr, row, record.text, record.id)
            M.LoadedTexts[bufnr][record.id] = record.text
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
    M.save_all(bufnr)  -- merges our unsaved changes with theirs
    M.restore_marks(bufnr)
    M.refresh_sign_bar(bufnr)
    return true
end

--- Restore A-Z marks for files not opened yet, so `'A` can jump to them (opt-in: g:nvim_marks_restore_global)
--- The store only holds rows, the anchor is matched when the file is opened
function M.restore_global_marks(bufnr)
    if vim.g.nvim_marks_restore_global ~= 1 then return end
    local _, info, store_path = locate_store(bufnr)
    if not info.top then return end
    for _, record in ipairs(store.load(store_path)) do
        local path = vim.startswith(record.file, '/') and record.file or (info.top .. '/' .. record.file)
        if record.kind == 'mark' and record.char:match('[A-Z]') and vim.fn.getpos("'" .. record.char)[2] == 0 and vim.fn.filereadable(path) == 1 then
            vim.fn.setpos("'" .. record.char, {vim.fn.bufadd(path), record.row, 1, 0})
        end
    end
end

--- @return string, string # buffer's file key (path from repo root), its repo's store file
function M.buffer_store(bufnr)
    local path, info, store_path = locate_store(bufnr)
    return store.file_key(path, info), store_path
end

--- Change (text) or delete (text=nil) a note/mark saved for a file that isn't open
function M.edit_stored(store_path, id, text)
    store.edit_record(store_path, id, text)
end

--- Every note and mark saved for the repo of `bufnr`, for listing files that aren't open
--- Open buffers have newer info in memory (unsaved additions/deletions), so the caller should prefer those
---
--- @return table[] # records with `path` added: [{id, file, path, kind='note'|'mark', char, text, row, line}], by file and row
function M.scan_repo_items(bufnr)
    local _, info, store_path = locate_store(bufnr)
    local items = store.load(store_path)
    for _, record in ipairs(items) do
        record.path = (vim.startswith(record.file, '/') or not info.top) and record.file or (info.top .. '/' .. record.file)
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

return M
