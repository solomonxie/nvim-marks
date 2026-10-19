local M = {}

local anchor = require('nvim-marks.anchor')
local store = require('nvim-marks.store')

M.NS_Signs = vim.api.nvim_create_namespace('nvim-marks.signs')
M.NS_Notes = vim.api.nvim_create_namespace('nvim-marks.notes')
M.NoteTexts = {}  --- @type table<integer, table<integer, string[]>> # {bufnr={mark_id=lines}}
M.note_style = vim.g.nvim_marks_note_style or 'inline'  --- @type 'inline'|'above' # set by setup()
M.note_prefix = '    -- '  --- @type string # before an inline note
M.Orphans = {}  --- @type table<integer, table[]> # {bufnr={orphan}}, marks/notes not found in the buffer's current version

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
    local info = store.repo_info(path)
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

--- Get notes(extmarks) from given buffer
---
--- @return table[] # list of extmark details [{mark_id, row, text}, {...}]
function M.scan_notes(bufnr)
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
function M.set_note(bufnr, row, text)
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

--- Save this buffer's marks+notes into the repo's store, leaving other files' entries alone
function M.save_all(bufnr)
    if not M.is_real_file(bufnr) or not vim.api.nvim_buf_is_loaded(bufnr) then return end
    local path, info, store_path = locate_store(bufnr)
    local key = store.file_key(path, info)
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local entry = {snapshot=lines, marks={}, notes={}, orphans=M.Orphans[bufnr] or {}}
    for _, item in ipairs(M.scan_vimmarks(bufnr)) do
        local char, row = unpack(item)
        table.insert(entry.marks, {char=char, anchor=anchor.make(lines, row)})
    end
    for _, item in ipairs(scan_buffer_global_marks(bufnr)) do
        local char, row = unpack(item)
        table.insert(entry.marks, {char=char, anchor=anchor.make(lines, row)})
    end
    for _, item in ipairs(M.scan_notes(bufnr)) do
        local _, row, text = unpack(item)
        table.insert(entry.notes, {text=text, anchor=anchor.make(lines, row)})
    end
    -- Re-read right before writing, another nvim (e.g. in another worktree) may have saved meanwhile
    local data = store.load(store_path)
    if #entry.marks + #entry.notes + #entry.orphans > 0 then
        data.files[key] = entry
    elseif data.files[key] == nil then
        return
    else
        data.files[key] = nil
    end
    store.save(store_path, data)
end

--- Restore marks+notes of a buffer from the repo's store
function M.restore_marks(bufnr)
    local path, info, store_path = locate_store(bufnr)
    local key = store.file_key(path, info)
    local entry = store.load(store_path).files[key]
    -- Start clean, `:e!` can keep some old note extmarks
    vim.api.nvim_buf_clear_namespace(bufnr, M.NS_Notes, 0, -1)
    M.NoteTexts[bufnr] = {}
    if entry == nil then
        local legacy = store.load_legacy(info, key)
        if legacy == nil then return end
        -- Old version saved rows only: restore at those rows as they are
        for _, mark in ipairs(legacy.marks) do pcall(M.set_vimmark, bufnr, mark.char, mark.row) end
        for _, note in ipairs(legacy.notes) do pcall(M.set_note, bufnr, note.row, note.text) end
        return
    end
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local hunks = entry.snapshot and anchor.diff(entry.snapshot, lines) or nil
    local orphans = {}
    local function restore(item, place)
        local row = anchor.locate(item.anchor, lines, hunks)
        if row then
            place(row)
        else
            table.insert(orphans, item)
        end
    end
    for _, mark in ipairs(entry.marks or {}) do
        restore(mark, function(row) vim.api.nvim_buf_set_mark(bufnr, mark.char, row, 0, {}) end)
    end
    for _, note in ipairs(entry.notes or {}) do
        restore(note, function(row) M.set_note(bufnr, row, note.text) end)
    end
    -- Orphans from earlier get another try, e.g. back on the branch where their line exists
    for _, item in ipairs(entry.orphans or {}) do
        restore(item, function(row)
            if item.char then
                vim.api.nvim_buf_set_mark(bufnr, item.char, row, 0, {})
            else
                M.set_note(bufnr, row, item.text)
            end
        end)
    end
    M.Orphans[bufnr] = orphans
end

--- Restore A-Z marks for files not opened yet, so `'A` can jump to them (opt-in: g:nvim_marks_restore_global)
--- The store only holds rows, the anchor is matched when the file is opened
function M.restore_global_marks(bufnr)
    if vim.g.nvim_marks_restore_global ~= 1 then return end
    local _, info, store_path = locate_store(bufnr)
    if not info.top then return end
    for key, entry in pairs(store.load(store_path).files) do
        local path = vim.startswith(key, '/') and key or (info.top .. '/' .. key)
        for _, mark in ipairs(entry.marks or {}) do
            if mark.char:match('[A-Z]') and vim.fn.getpos("'" .. mark.char)[2] == 0 and vim.fn.filereadable(path) == 1 then
                vim.fn.setpos("'" .. mark.char, {vim.fn.bufadd(path), mark.anchor.row, 1, 0})
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

return M
