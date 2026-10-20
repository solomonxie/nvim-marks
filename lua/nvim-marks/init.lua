--- NOTE:
--- 1. We use native Vimmarks for marks, we use extmarks for notes
--- 2. We try not to disrupt native vimmarks key bindings, will just forward the keystroke
--- 3. We save all info into one file per repo (shared by its worktrees), see store.lua; lines are re-found with anchor.lua
--- 4. For vim global marks (A-Z), the problem is that we cannot restore the mark without opening the file,
---    which is tricky because we don't want to open a buffer which may trigger other plugin reactions.
---    An easier way: we only restore marks upon BufEnter, if user wants to jump to global marks, has to jump from Marks window,
---    so `'A` won't jump until buffer is opened at least once (unless viminfo/shada were enabled)
--- 5. Marks are for the CURRENT BUFFER; the notes list covers every file in the repo

local M = {}

local utils = require('nvim-marks.utils')

local IsBufferSetup = {}
local NS_Preview = vim.api.nvim_create_namespace('nvim-marks.preview')
local NS_Placeholder = vim.api.nvim_create_namespace('nvim-marks.placeholder')
local EditKey = 'e'  -- edits the note under the cursor in the menu
local PanelMarkChars = 'ABCDEFHIJKLMOPQRSTUVWXYZ'  -- capitals set a mark from the menu; lowercase keys (and G, N) keep their normal meaning there
local NoteWidth = 80  -- notes column in the menu is as wide as the longest note, up to this; longer ones are cut with `…`
local PathWidthMax = 50  -- the path column is as wide as the longest path, up to this
local MarksMetadata = {}  -- {win_bufnr: {row: metadata}}, kept in Lua since vim.b turns sparse tables into lists


--- Cut or pad a string to exactly `width` display columns, `…` where it was cut
local function fit(text, width)
    if vim.fn.strdisplaywidth(text) > width then
        local chars = vim.fn.strchars(text)
        while chars > 0 and vim.fn.strdisplaywidth(vim.fn.strcharpart(text, 0, chars)) > width - 1 do
            chars = chars - 1
        end
        text = vim.fn.strcharpart(text, 0, chars) .. '…'
    end
    return text .. string.rep(' ', width - vim.fn.strdisplaywidth(text))
end

--- @return integer # widest of the strings up to `cap`, so the column after them lines up
local function column_width(strings, cap)
    local width = 0
    for _, text in ipairs(strings) do width = math.max(width, vim.fn.strdisplaywidth(text)) end
    return math.min(width, cap)
end

--- @return string # a note's lines on one line
local function note_summary(note_lines)
    return table.concat(vim.tbl_filter(function(l) return vim.trim(l) ~= '' end, note_lines), ' | ')
end

--- @return string # `>> path:row  "line text"` shown after a note in the menu
local function note_tail(location, path_width, line_text)
    local tail = ' >> ' .. fit(location, path_width)
    if line_text ~= '' then tail = tail .. '  "' .. line_text:sub(1, 80) .. '"' end
    return tail
end


--- Swith to note editing mode allows user to type notes, starts in insert mode with a hint shown above the text
---
--- @param initial string[]|nil # existing note's lines, to edit it
--- @param on_save function|nil # called with the typed lines; default adds a note at target_row
function M.switchEditMode(target_bufnr, target_row, initial, on_save)
    local edit_bufnr = M.create_window()
    if initial then vim.api.nvim_buf_set_lines(edit_bufnr, 0, -1, false, initial) end
    -- Hint as a gray line above the text, always shown; it isn't part of the note
    local function show_hint()
        vim.api.nvim_buf_clear_namespace(edit_bufnr, NS_Placeholder, 0, -1)
        vim.api.nvim_buf_set_extmark(edit_bufnr, NS_Placeholder, 0, 0, {
            virt_lines={{{'> Type a note | `Ctrl-s`/`Ctrl-c`/`:w` save and quit | `q` (normal mode) quit', 'Comment'}}},
            virt_lines_above=true,
            right_gravity=false,  -- stays on line 1 when lines are inserted at the top
        })
    end
    show_hint()
    -- Deleting line 1 (e.g. `dd`) removes the extmark with it, so put it back
    vim.api.nvim_create_autocmd({'TextChanged', 'TextChangedI'}, {buffer=edit_bufnr, callback=show_hint})
    on_save = on_save or function(text) utils.set_note(target_bufnr, target_row, text) end
    for _, key in ipairs({'<C-s>', '<C-c>'}) do
        vim.keymap.set({'n', 'i', 'v'}, key, function() M.save_note(edit_bufnr, target_bufnr, on_save) end, {buffer=true, silent=true, nowait=true })
    end
    -- `:w` / `:wq` / `:x` save the note too: an acwrite buffer hands the write to us instead of to a file
    vim.bo[edit_bufnr].buftype = 'acwrite'
    vim.api.nvim_buf_set_name(edit_bufnr, 'nvim-marks://note/' .. edit_bufnr)
    vim.bo[edit_bufnr].modified = false
    vim.api.nvim_create_autocmd('BufWriteCmd', {buffer=edit_bufnr, callback=function()
        M.save_note(edit_bufnr, target_bufnr, on_save, true)
    end})
    if initial then
        vim.api.nvim_win_set_cursor(0, {#initial, 0})  -- an existing note opens in normal mode
    else
        vim.cmd('startinsert')
    end
end

--- Edit a note listed in the menu, open buffer (extmark) or saved file
function M.edit_note(note)
    M.switchEditMode(note.bufnr, note.row, note.text, function(text)
        if note.extmark_id then
            local record_id = utils.RecordIds[note.bufnr].notes[note.extmark_id]
            vim.api.nvim_buf_del_extmark(note.bufnr, utils.NS_Notes, note.extmark_id)
            utils.set_note(note.bufnr, note.row, text, record_id)  -- same record, so it keeps its line in the store
        else
            utils.edit_stored(note.store_path, note.id, text)
        end
    end)
end

function M.openMarks()
    local target_bufnr = vim.api.nvim_get_current_buf()
    local target_row, _ = unpack(vim.api.nvim_win_get_cursor(0))  -- 0: current window_id
    local filename = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(target_bufnr), ":.")
    -- Prepare content
    local content_lines = {
        '> Help: Press a capital letter to add that mark (not G N) | `+` Add note | `' .. EditKey .. '` Edit note | `-` Delete (y/n) | `<CR>` Jump | `q` Quit',
    }
    local previews = {}  -- {window_row: text}, appended in gray after each item
    -- Render marks
    local marks_metadata = {}
    local vimmarks = utils.scan_vimmarks(target_bufnr)
    local global_marks = utils.scan_global_vimmarks()
    if #vimmarks + #global_marks > 0 then
        table.insert(content_lines, '')
        table.insert(content_lines, '# Marks')
    end
    for _, item in ipairs(vimmarks) do
        local char, row = unpack(item)
        local display = string.format("(%s) %s:%d", char, filename, row)
        table.insert(content_lines, display)
        previews[#content_lines] = utils.line_preview(target_bufnr, row)
        marks_metadata[#content_lines] = { type = 'mark', char = char, row = row, filename = filename }
    end
    -- Render global marks
    for _, item in ipairs(global_marks) do
        local char, row, global_filename = unpack(item)
        local display = string.format("(%s) %s:%d", char, global_filename, row)
        table.insert(content_lines, display)
        previews[#content_lines] = utils.line_preview(vim.fn.bufnr(global_filename), row)
        marks_metadata[#content_lines] = { type = 'global', char = char, row = row, filename = global_filename }
    end
    -- Render notes of every file in the repo: open buffers from memory (has unsaved changes), the rest from the store
    local notes = {}
    local _, store_path = utils.buffer_store(target_bufnr)
    local live_keys = {}
    local function add_live(bufnr)
        local key, buf_store_path = utils.buffer_store(bufnr)
        if buf_store_path ~= store_path then return end
        live_keys[key] = true
        local name = key  -- path from the repo root, the same as for closed files, so the order doesn't depend on cwd
        for _, item in ipairs(utils.scan_notes(bufnr)) do
            local id, row, note_lines = unpack(item)
            table.insert(notes, {bufnr=bufnr, extmark_id=id, row=row, text=note_lines, filename=name, line=utils.line_preview(bufnr, row)})
        end
    end
    add_live(target_bufnr)
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if bufnr ~= target_bufnr and IsBufferSetup[bufnr] and vim.api.nvim_buf_is_loaded(bufnr) then add_live(bufnr) end
    end
    for _, item in ipairs(utils.scan_repo_items(target_bufnr)) do
        if item.kind == 'note' and not live_keys[item.file] then
            table.insert(notes, {id=item.id, path=item.path, store_path=store_path,
                                 row=item.row, text=item.text, filename=item.file, line=vim.trim(item.line or '')})
        end
    end
    -- Always the same order, wherever the menu is opened from: by path from the repo root, then row
    table.sort(notes, function(a, b)
        if a.filename ~= b.filename then return a.filename < b.filename end
        return a.row < b.row
    end)
    if #notes ~= 0 then
        table.insert(content_lines, '')
        table.insert(content_lines, '# Notes (' .. #notes .. ')')
    end
    local note_width = column_width(vim.tbl_map(function(note) return note_summary(note.text) end, notes), NoteWidth)
    local path_width = column_width(vim.tbl_map(function(note) return note.filename .. ':' .. note.row end, notes), PathWidthMax)
    local number_width = #tostring(#notes)
    for i, note in ipairs(notes) do
        local number = string.rep(' ', number_width - #tostring(i)) .. i .. '.'
        table.insert(content_lines, number .. ' ' .. fit(note_summary(note.text), note_width))
        previews[#content_lines] = note_tail(note.filename .. ':' .. note.row, path_width, note.line)
        marks_metadata[#content_lines] = vim.tbl_extend('force', note, { type = 'note' })
    end
    -- Render orphans: saved marks/notes whose line isn't in this version of the file (e.g. another branch)
    local orphans = utils.Orphans[target_bufnr] or {}
    if #orphans ~= 0 then
        table.insert(content_lines, '')
        table.insert(content_lines, '# Not found in this version (kept until deleted)')
    end
    local function orphan_label(item) return item.char and ('(' .. item.char .. ')') or ('* ' .. note_summary(item.text)) end
    local orphan_width = column_width(vim.tbl_map(orphan_label, orphans), NoteWidth + 2)
    local orphan_path_width = column_width(vim.tbl_map(function(item) return filename .. ':' .. item.row end, orphans), PathWidthMax)
    for i, item in ipairs(orphans) do
        table.insert(content_lines, fit(orphan_label(item), orphan_width))
        previews[#content_lines] = note_tail(filename .. ':' .. item.row, orphan_path_width, vim.trim(item.line))
        marks_metadata[#content_lines] = { type = 'orphan', index = i, char = item.char, row = item.row, filename = filename }
    end
    -- Append each item's path/line text, remembering where the gray part starts
    local gray_from = {}
    for row, preview in pairs(previews) do
        if preview ~= '' then
            if row > 1 and not preview:match('^ >> ') then preview = '  ' .. preview:sub(1, 80) end
            gray_from[row] = #content_lines[row]
            content_lines[row] = content_lines[row] .. preview
        end
    end
    -- Create a window and display
    local win_bufnr = M.create_window()
    MarksMetadata[win_bufnr] = marks_metadata
    vim.api.nvim_buf_set_lines(win_bufnr, 0, -1, false, content_lines)
    -- Put the cursor on the mark/note of the line we came from, if any
    for row = 1, #content_lines do
        local item = marks_metadata[row]
        local here = item and (item.type == 'note' and item.bufnr == target_bufnr or item.type ~= 'note' and item.filename == filename)
        if here and item.type ~= 'orphan' and item.row == target_row then
            vim.api.nvim_win_set_cursor(0, {row, 0})
            break
        end
    end
    -- Gray the path and line text, kept as real text so `/` search finds them
    for row, start_col in pairs(gray_from) do
        vim.api.nvim_buf_set_extmark(win_bufnr, NS_Preview, row-1, start_col, {
            end_row=row-1, end_col=#content_lines[row], hl_group='Comment', priority=200,
        })
    end
    -- Help line in gray, over the markdown highlighting
    vim.api.nvim_buf_set_extmark(win_bufnr, NS_Preview, 0, 0, {end_row=1, hl_group='Comment', hl_eol=true, priority=200})
    vim.cmd('setlocal nomodifiable')
    -- Key: any letter adds that mark, except the menu's own keys
    local opts = { buffer = win_bufnr, silent = true, nowait = true }
    for char in PanelMarkChars:gmatch('.') do
        vim.keymap.set('n', char, function()
            utils.set_vimmark(target_bufnr, char, target_row)
            utils.refresh_sign_bar(target_bufnr)
            vim.cmd('bwipeout!')
            vim.api.nvim_echo({{'Added mark: '..char, 'Normal'}}, false, {})
        end, opts)
    end
    -- Key: Add a note, or edit the one already on this line
    vim.keymap.set('n', '+', function()
        for _, note in ipairs(notes) do
            if note.bufnr == target_bufnr and note.row == target_row then return M.edit_note(note) end
        end
        M.switchEditMode(target_bufnr, target_row)
    end, opts)
    -- Key: Edit the note under the cursor
    vim.keymap.set('n', EditKey, function()
        local mark = M.get_mark_at_cursor()
        if mark and mark.type == 'note' then
            M.edit_note(mark)
        else
            vim.api.nvim_echo({{'Not on a note', 'WarningMsg'}}, false, {})
        end
    end, opts)
    -- Key: Jump to mark/note
    vim.keymap.set('n', '<CR>', function()
        local mark = M.get_mark_at_cursor()
        if mark and mark.type == 'orphan' then
            vim.api.nvim_echo({{'Not found in this version of the file', 'WarningMsg'}}, false, {})
        elseif mark then
            vim.cmd('bwipeout!')
            if mark.type == 'global' then
                vim.cmd('edit ' .. mark.filename)
                vim.api.nvim_win_set_cursor(0, {mark.row, 0})
            elseif mark.type == 'note' and mark.bufnr ~= target_bufnr then
                M.jump_to_note(mark)
            else
                vim.api.nvim_set_current_buf(target_bufnr)
                vim.api.nvim_win_set_cursor(0, {mark.row, 0})
            end
        end
    end, opts)
    -- Key: Delete a mark/note
    vim.keymap.set('n', '-', function()
        local mark = M.get_mark_at_cursor()
        local label = mark and (mark.char and ('mark ' .. mark.char) or 'note') .. ' at ' .. mark.filename .. ':' .. mark.row
                      or ('marks/notes at line ' .. target_row)
        if not M.confirm('Delete ' .. label .. '?') then return end
        if mark then
            if mark.type == 'global' or mark.type == 'mark' then
                local bufnr = mark.type == 'global' and vim.fn.bufadd(mark.filename) or target_bufnr
                vim.api.nvim_buf_del_mark(bufnr, mark.char)
                utils.refresh_sign_bar(bufnr)
            elseif mark.type == 'note' and mark.extmark_id then
                vim.api.nvim_buf_del_extmark(mark.bufnr, utils.NS_Notes, mark.extmark_id)
                utils.refresh_sign_bar(mark.bufnr)
            elseif mark.type == 'note' then
                utils.edit_stored(mark.store_path, mark.id, nil)
            elseif mark.type == 'orphan' then
                utils.delete_orphan(target_bufnr, mark.index)
            end
            vim.cmd('bwipeout!')
            vim.api.nvim_echo({{'Deleted ' .. label, 'Normal'}}, false, {})
        else
            -- Not on an item: delete everything on the line we came from
            utils.delete_vimmark(target_bufnr, target_row)
            utils.delete_note(target_bufnr, target_row)
            utils.refresh_sign_bar(target_bufnr)
            vim.api.nvim_echo({{'Deleted marks/notes at line ' .. target_row, 'Normal'}}, false, {})
            vim.cmd('bwipeout!')
        end
    end, opts)
    vim.cmd('redraw')
end

--- Open a note's file and put the cursor on it (the note may have moved since it was saved)
function M.jump_to_note(note)
    if note.bufnr then
        vim.api.nvim_set_current_buf(note.bufnr)
    else
        vim.cmd('edit ' .. vim.fn.fnameescape(note.path))
    end
    local bufnr = vim.api.nvim_get_current_buf()
    local row = note.row
    for _, item in ipairs(utils.scan_notes(bufnr)) do
        local id, item_row, text = unpack(item)
        if id == note.extmark_id or vim.deep_equal(text, note.text) then row = item_row; break end
    end
    vim.api.nvim_win_set_cursor(0, {math.min(row, vim.api.nvim_buf_line_count(bufnr)), 0})
end

--- Ask y/n, anything but y/Y is no
--- @return boolean
function M.confirm(question)
    vim.api.nvim_echo({{question .. ' [y/N] ', 'WarningMsg'}}, false, {})
    local ok, answer = pcall(vim.fn.getcharstr)
    vim.api.nvim_echo({{'', 'Normal'}}, false, {})
    return ok and (answer == 'y' or answer == 'Y')
end

--- Get mark info at current cursor line using metadata stored in buffer
--- @return table|nil # {type='mark'|'note'|'global', char=string, id=number, row=number, filename=string}
function M.get_mark_at_cursor()
    local row, _ = unpack(vim.api.nvim_win_get_cursor(0))
    local metadata = MarksMetadata[vim.api.nvim_get_current_buf()] or {}
    return metadata[row]
end

--- @return integer # Mark-window's Buffer id
function M.create_window()
    if vim.b.is_marks_window == true then vim.cmd('bwipeout!') end  -- Close existing quick window
    vim.cmd('botright 10 new')  -- Create new window and jump to the buffer context
    vim.b.is_marks_window = true
    vim.opt_local.buftype = 'nofile'
    vim.opt_local.filetype = 'markdown'
    vim.cmd('mapclear <buffer>')
    vim.cmd('autocmd BufLeave,BufWinLeave,BufHidden <buffer> ++once  :bd!')
    vim.cmd('nnoremap <buffer> <silent> <nowait> q :bwipeout!<CR>')
    vim.cmd('nnoremap <buffer> <silent> <nowait> <ESC> :bwipeout!<CR>')
    vim.cmd('nnoremap <buffer> <silent> <nowait> <C-c> :bwipeout!<CR>')
    vim.cmd('setlocal buftype=nofile bufhidden=wipe noswapfile nonumber norelativenumber nowrap nocursorline')
    return vim.api.nvim_get_current_buf()
end

--- Read from user edits, save it to an extmark attached to the target
---
--- @param edit_bufnr integer # editor-buffer's id
--- @param target_bufnr integer|nil # target-buffer's id, nil for a note of a file that isn't open
--- @param on_save function # called with the typed lines
--- @param from_write boolean|nil # called by `:w`/`:wq`/`:x`: close after the command, so its `q` still has a window
function M.save_note(edit_bufnr, target_bufnr, on_save, from_write)
    local text = vim.api.nvim_buf_get_lines(edit_bufnr, 0, -1, false)
    if vim.trim(table.concat(text, '\n')) ~= '' then  -- Nothing typed: just close
        on_save(text)
    end
    if target_bufnr then utils.refresh_sign_bar(target_bufnr) end
    vim.bo[edit_bufnr].modified = false
    local function close()
        if vim.api.nvim_buf_is_valid(edit_bufnr) then vim.api.nvim_buf_delete(edit_bufnr, {force=true}) end
        vim.cmd('stopinsert!')
    end
    if from_write then vim.schedule(close) else close() end
end

--- On buffer load, restore marks from persistent file
--- Runs again after the buffer is unloaded (`:bd`) or reloaded (`:e!`), which drop its notes
function M.setupBuffer()
    local bufnr = vim.api.nvim_get_current_buf()
    local is_file = utils.is_real_file(bufnr)
    if not is_file then return end
    if IsBufferSetup[bufnr] then return end
    utils.restore_marks(bufnr)
    utils.restore_global_marks(bufnr)
    utils.refresh_sign_bar(bufnr)
    -- Register auto saving/updating logic, in a group so a re-setup replaces them instead of adding more
    local group = vim.api.nvim_create_augroup('nvim-marks-buf-' .. bufnr, {clear=true})
    vim.api.nvim_create_autocmd({'BufLeave', 'VimLeavePre'}, {
        group = group,
        buffer = bufnr,
        callback = function() utils.save_all(bufnr) end,
    })
    vim.api.nvim_create_autocmd('BufEnter', {
        group = group,
        buffer = bufnr,
        callback = function() utils.refresh_sign_bar(bufnr) end,
    })
    -- Save before the notes are gone, then set up again next time the buffer is loaded
    vim.api.nvim_create_autocmd({'BufUnload', 'BufReadPre'}, {
        group = group,
        buffer = bufnr,
        callback = function()
            utils.save_all(bufnr)
            IsBufferSetup[bufnr] = nil
            vim.api.nvim_del_augroup_by_id(group)
        end,
    })
    IsBufferSetup[bufnr] = true
end


--- Check every few seconds whether the marks file changed on disk (another nvim, a `git pull`) and reload the
--- notes of open buffers. A stat per repo is all it costs when nothing changed.
local ReloadTimer = nil
function M.start_auto_reload(interval_ms)
    if ReloadTimer then ReloadTimer:stop(); ReloadTimer:close(); ReloadTimer = nil end
    if not interval_ms or interval_ms <= 0 then return end
    ReloadTimer = vim.uv.new_timer()
    ReloadTimer:start(interval_ms, interval_ms, vim.schedule_wrap(function()
        if vim.fn.mode() ~= 'n' or vim.b.is_marks_window then return end  -- don't redraw under the user mid-edit
        for bufnr in pairs(IsBufferSetup) do
            if vim.api.nvim_buf_is_valid(bufnr) then utils.reload_if_changed(bufnr) end
        end
    end))
end

--- @param opt table|nil # {dir=string} folder where marks are saved (see store.lua)
---                         {reload_interval=10} seconds between checks for changes from elsewhere, 0 turns it off
---                         {note_style='inline'|'above'} notes at the end of the line (default) or on lines above it
---                         {note_prefix=string} before an inline note, default '    -- '
function M.setup(opt)
    opt = opt or {}
    if opt.note_style then utils.note_style = opt.note_style end
    if opt.note_prefix then utils.note_prefix = opt.note_prefix end
    if opt.dir then require('nvim-marks.store').dir_option = opt.dir end
    if opt.reload_interval then M.start_auto_reload(opt.reload_interval * 1000) end
end

M.start_auto_reload((vim.g.nvim_marks_reload_interval or 10) * 1000)

return M
