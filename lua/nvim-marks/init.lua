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
local EditKey = 'o'  -- edits the note under the cursor in the menu
local PanelMarkChars = 'ABCDEFHIJKLMOPQRSTUVWXYZ'  -- capitals set a mark from the menu; other lowercase keys (and G, N) keep their normal meaning there
local NoteWidth = 80  -- notes column in the menu is as wide as the longest note, up to this; longer ones are cut with `…`
local PathWidthMax = 50  -- the path column is as wide as the longest path, up to this
local MenuOrigin = nil  -- {win, bufnr, row} the marks list was last opened from, for `[` in the editor to go back to
local StatusTitles = {open='Notes', todo='TODO', done='DONE', anchor='Anchors'}
local SectionOrder = {'open', 'todo', 'anchor', 'done'}  -- list sections top to bottom (same as the `@` cycle)
local MarksMetadata = {}  -- {win_bufnr: {row: metadata}}, kept in Lua since vim.b turns sparse tables into lists
local Peek = nil  -- {win, bufnr, view, opened, keep}: the code window showing the menu item under the cursor, see peek()


--- Cut or pad a string to exactly `width` display columns, `…` where it was cut
local function fit(text, width)
    if vim.fn.strdisplaywidth(text) > width then
        -- Cut at `width` characters first (a char is at least one column), then drop the few that are wide;
        -- notes can be hundreds of characters, so shortening one character at a time was slow
        local chars = width - 1
        text = vim.fn.strcharpart(text, 0, chars)
        while chars > 0 and vim.fn.strdisplaywidth(text) > width - 1 do
            chars = chars - 1
            text = vim.fn.strcharpart(text, 0, chars)
        end
        text = text .. '…'
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
    return utils.one_line(note_lines)
end

--- @return string # `>> path:row  "line text"` shown after a note in the menu
local function note_tail(location, path_width, line_text)
    local tail = ' >> ' .. fit(location, path_width)
    if line_text ~= '' then tail = tail .. '  "' .. line_text:sub(1, 80) .. '"' end
    return tail
end


--- Show the menu item under the cursor in the code window the menu was opened from, at its line. The same window
--- is reused for every item; files are opened with :edit (ordinary buffers). A file the preview opened is closed
--- when it moves to another file, so there's one at a time; files you had open are left alone.
local function peek(item)
    if not (Peek and item and vim.api.nvim_win_is_valid(Peek.win)) then return end
    local bufnr, path = nil, nil
    if item.type == 'mark' then
        bufnr = Peek.bufnr
    elseif item.type == 'global' then
        path = item.path
    elseif item.type == 'note' then
        bufnr = item.bufnr
        if not bufnr and item.exists ~= false then path = item.path end
    end
    if not (path or (bufnr and vim.api.nvim_buf_is_valid(bufnr))) then return end
    local opened
    bufnr, opened = utils.show_in_window(Peek.win, path or bufnr)
    if not bufnr then return end
    if Peek.opened and Peek.opened ~= bufnr then utils.close_preview_buffer(Peek.opened) end
    if opened then Peek.opened = bufnr elseif Peek.opened ~= bufnr then Peek.opened = nil end
    local row = item.row
    if item.type == 'note' then row = M.find_note_row(bufnr, item) end
    row = math.max(1, math.min(row, vim.api.nvim_buf_line_count(bufnr)))
    vim.api.nvim_win_set_cursor(Peek.win, {row, 0})
    vim.api.nvim_win_call(Peek.win, function() vim.cmd('normal! zz') end)
end

--- The menu closed: put the code window back on the file and view it had, and close the file the preview opened,
--- unless <CR> jumped to the item shown (then it stays open).
local function end_peek()
    if not Peek then return end
    local state = Peek
    Peek = nil
    if state.keep then return end
    -- Scheduled: the menu closes from inside autocmds, where the file's own BufEnter hooks wouldn't run
    vim.schedule(function()
        if vim.api.nvim_win_is_valid(state.win) and vim.api.nvim_buf_is_valid(state.bufnr) then
            utils.show_in_window(state.win, state.bufnr)
            vim.api.nvim_win_call(state.win, function() vim.fn.winrestview(state.view) end)
        end
        utils.close_preview_buffer(state.opened)
    end)
end


--- Swith to note editing mode allows user to type notes, starts in insert mode with a hint shown above the text
---
--- @param initial string[]|nil # existing note's lines, to edit it
--- @param on_save function|nil # called with the typed lines; default adds a note at target_row
--- @param on_delete function|nil # deletes the existing note, for `-` in normal mode; nil for a new note
--- @param status_ops table|nil # {get=fn() -> status, cycle=fn() -> new status} for `@`; nil for a new note
function M.switchEditMode(target_bufnr, target_row, initial, on_save, on_delete, status_ops)
    local edit_bufnr = M.create_window()
    if initial then vim.api.nvim_buf_set_lines(edit_bufnr, 0, -1, false, initial) end
    -- Hint in the window's top bar: always visible however the text scrolls, and not part of the note
    -- (a virtual line above line 1 hides as soon as the view scrolls past it)
    local function show_hint()
        -- q and < save the note as they leave (there's no separate save key); - and @ only exist for saved notes
        local hint = 'Help: q quit | Backspace return to main menu'
        if on_delete then hint = hint .. ' | - delete this note' end
        if status_ops then
            local status = status_ops.get()
            local symbol = require('nvim-marks.store').STATUS_SYMBOLS[status]
            hint = (symbol ~= '' and symbol .. ' ' or '') .. StatusTitles[status] .. ' | ' .. hint .. ' | @ change status'
        end
        vim.wo.winbar = '%#Comment#' .. hint:gsub('%%', '%%%%')
    end
    show_hint()
    -- Key: next status, saved right away (the text is saved separately, when you save the note)
    if status_ops then
        vim.keymap.set('n', '@', function()
            local status = status_ops.cycle()
            show_hint()
            vim.api.nvim_echo({{'Status: ' .. StatusTitles[status], 'Normal'}}, false, {})
        end, {buffer=edit_bufnr, silent=true, nowait=true})
    end
    -- Margin under the bar: a virtual blank line above line 1, not part of the note. nvim only draws a line
    -- above the first one when the view says so (topfill), so ask for it now and whenever it scrolls back to the top
    local function show_margin()
        -- Editing line 1 (`O`, `dd`) can move or drop the extmark, so put it back on line 1 each time
        vim.api.nvim_buf_clear_namespace(edit_bufnr, NS_Preview, 0, -1)
        vim.api.nvim_buf_set_extmark(edit_bufnr, NS_Preview, 0, 0, {virt_lines={{{'', 'Normal'}}}, virt_lines_above=true})
        if vim.api.nvim_get_current_buf() ~= edit_bufnr then return end
        local view = vim.fn.winsaveview()
        if view.topline == 1 and view.topfill == 0 then vim.fn.winrestview({topline=1, topfill=1}) end
    end
    vim.api.nvim_create_autocmd({'CursorMoved', 'CursorMovedI', 'WinScrolled', 'TextChanged', 'TextChangedI'}, {buffer=edit_bufnr, callback=show_margin})
    on_save = on_save or function(text) utils.set_note(target_bufnr, target_row, text) end
    -- Key: save, then back to the marks list, opened for the file and line the editor was opened from
    vim.keymap.set('n', '<BS>', function()
        local origin = MenuOrigin
        M.save_note(edit_bufnr, target_bufnr, on_save, false, on_delete)
        if origin and vim.api.nvim_win_is_valid(origin.win) and vim.api.nvim_buf_is_valid(origin.bufnr) then
            vim.api.nvim_set_current_win(origin.win)
            vim.api.nvim_win_set_buf(origin.win, origin.bufnr)
            vim.api.nvim_win_set_cursor(origin.win, {math.min(origin.row, vim.api.nvim_buf_line_count(origin.bufnr)), 0})
            M.openMarks()
        end
    end, {buffer=edit_bufnr, silent=true, nowait=true})
    -- Key: delete the note being edited, after a y/n
    if on_delete then
        vim.keymap.set('n', '-', function()
            if not M.confirm('Delete this note?') then return end
            on_delete()
            vim.bo[edit_bufnr].modified = false
            vim.api.nvim_buf_delete(edit_bufnr, {force=true})
            if target_bufnr then
                utils.save_all(target_bufnr)  -- to the store right away, like a save
                utils.refresh_sign_bar(target_bufnr)
            end
            vim.api.nvim_echo({{'Deleted note', 'Normal'}}, false, {})
        end, {buffer=edit_bufnr, silent=true, nowait=true})
    end
    -- Key: q (normal mode) saves the note and closes the editor
    vim.keymap.set('n', 'q', function() M.save_note(edit_bufnr, target_bufnr, on_save, false, on_delete) end, {buffer=edit_bufnr, silent=true, nowait=true})
    if initial then
        vim.api.nvim_win_set_cursor(0, {1, 0})  -- an existing note opens in normal mode, at its first line
    else
        vim.cmd('startinsert')
    end
    show_margin()
end

--- Edit a note listed in the menu, open buffer (extmark) or saved file
function M.edit_note(note)
    local opened_with = vim.deepcopy(note.text)
    M.switchEditMode(note.bufnr, note.row, note.text, function(text)
        -- Not changed in the editor: write nothing, so an edit made meanwhile elsewhere (an agent's reply) stays
        if vim.deep_equal(text, opened_with) then return end
        -- Changed: apply the user's edit on top of the latest text on disk if only lines were added at the end
        local latest = utils.latest_note_text(note)
        if latest and not vim.deep_equal(latest, opened_with) then
            text = utils.merge_note_edit(opened_with, latest, text)
        end
        if note.extmark_id then
            local record_id = utils.RecordIds[note.bufnr].notes[note.extmark_id]
            vim.api.nvim_buf_del_extmark(note.bufnr, utils.NS_Notes, note.extmark_id)
            utils.set_note(note.bufnr, note.row, text, record_id, note.status)  -- same record, so it keeps its line in the store
        else
            utils.edit_stored(note.store_path, note.id, text)
        end
    end, function()
        if note.extmark_id then
            vim.api.nvim_buf_del_extmark(note.bufnr, utils.NS_Notes, note.extmark_id)
        else
            utils.edit_stored(note.store_path, note.id, nil)
        end
    end, {
        get = function() return note.status or 'open' end,
        cycle = function() return M.cycle_status(note) end,
    })
end

--- @param opt table|nil # {focus=note}: put the cursor on this note instead of on the current line's
function M.openMarks(opt)
    opt = opt or {}
    -- Not from inside one of the plugin's own panels (menu, note editor, tour): `m` there does nothing
    if vim.b.is_marks_window then return end
    local target_bufnr = vim.api.nvim_get_current_buf()
    local target_row, _ = unpack(vim.api.nvim_win_get_cursor(0))  -- 0: current window_id
    MenuOrigin = {win=vim.api.nvim_get_current_win(), bufnr=target_bufnr, row=target_row}
    -- Path from the repo root, the same wherever nvim's cwd is (a `:cd` doesn't change what's shown or matched)
    local filename = utils.display_name(vim.api.nvim_buf_get_name(target_bufnr))
    -- Prepare content
    local content_lines = {''}  -- a blank first line: margin under the hint bar
    local hint = 'Help: A-Z (not G N) add mark | a add note | ' .. EditKey .. ' open note / tour | @ next status | - delete (y/n) | <Enter> jump | q quit'
    local previews = {}  -- {window_row: text}, appended in gray after each item
    -- Render marks
    local marks_metadata = {}
    local vimmarks = utils.scan_vimmarks(target_bufnr)
    local global_marks = utils.scan_global_vimmarks()
    local function section(title)  -- a blank line between sections, none before the first
        if #content_lines > 1 then table.insert(content_lines, '') end
        table.insert(content_lines, title)
    end
    if #vimmarks + #global_marks > 0 then
        section('# Marks')
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
        local char, row, path, name = unpack(item)
        local display = string.format("(%s) %s:%d", char, name, row)
        table.insert(content_lines, display)
        previews[#content_lines] = utils.line_preview(vim.fn.bufnr(path), row)
        marks_metadata[#content_lines] = { type = 'global', char = char, row = row, filename = name, path = path }
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
            local id, row, note_lines, status = unpack(item)
            table.insert(notes, {bufnr=bufnr, extmark_id=id, row=row, text=note_lines, status=status or 'open',
                                 filename=name, line=utils.line_preview(bufnr, row)})
        end
    end
    add_live(target_bufnr)
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if bufnr ~= target_bufnr and IsBufferSetup[bufnr] and vim.api.nvim_buf_is_loaded(bufnr) then add_live(bufnr) end
    end
    for _, item in ipairs(utils.scan_repo_items(target_bufnr)) do
        if item.kind == 'note' and not live_keys[item.file] and not utils.is_empty_note(item.text) then
            table.insert(notes, {id=item.id, path=item.path, exists=item.exists, store_path=store_path, status=item.status or 'open',
                                 row=item.row, text=item.text, filename=item.file, line=vim.trim(item.line or '')})
        end
    end
    -- Always the same order, wherever the menu is opened from: by path from the repo root, then row
    table.sort(notes, function(a, b)
        if a.filename ~= b.filename then return a.filename < b.filename end
        return a.row < b.row
    end)
    -- One section per status, done last; columns line up across all of them
    local function labeled(note)
        note.label = note.label or (utils.status_prefix(note.status) .. note_summary(note.text))
        return note.label
    end
    local note_width = column_width(vim.tbl_map(labeled, notes), NoteWidth)
    local path_width = column_width(vim.tbl_map(function(note) return note.filename .. ':' .. note.row end, notes), PathWidthMax)
    local number_width = #tostring(#notes)
    local dimmed = {}  -- {window_row=true}: done rows, drawn all in gray
    local i = 0
    -- Tours (guided marks) found in the repo's tours folder; <CR> on one starts guided mode. Listed above Anchors.
    local function render_tours()
        local tours = require('nvim-marks.tour').list(vim.fs.dirname(store_path))
        if #tours == 0 then return end
        section('# Tours (' .. #tours .. ')')
        for _, t in ipairs(tours) do
            local label = t.error and ('(!) ' .. t.name) or (t.name .. ' (' .. t.steps_count .. ' steps)')
            table.insert(content_lines, '  ' .. label)
            previews[#content_lines] = t.error or t.description or ''
            marks_metadata[#content_lines] = {type='tour', path=t.path, error=t.error}
        end
    end
    local tours_rendered = false
    for _, status in ipairs(SectionOrder) do
        if status == 'anchor' then render_tours(); tours_rendered = true end
        local group = vim.tbl_filter(function(note) return note.status == status end, notes)
        if #group > 0 then
            section('# ' .. StatusTitles[status] .. ' (' .. #group .. ')')
            for _, note in ipairs(group) do
                i = i + 1
                local number = string.rep(' ', number_width - #tostring(i)) .. i .. '.'
                table.insert(content_lines, number .. ' ' .. fit(labeled(note), note_width))
                previews[#content_lines] = note_tail(note.filename .. ':' .. note.row, path_width, note.line)
                marks_metadata[#content_lines] = vim.tbl_extend('force', note, { type = 'note' })
                if status == 'done' then dimmed[#content_lines] = true end
            end
        end
    end
    if not tours_rendered then render_tours() end
    -- Render orphans: saved marks/notes whose line isn't in this version of the file (e.g. another branch)
    local orphans = utils.Orphans[target_bufnr] or {}
    if #orphans ~= 0 then
        section('# Not found in this version (kept until deleted)')
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
            if not preview:match('^ >> ') then preview = '  ' .. preview:sub(1, 80) end
            gray_from[row] = #content_lines[row]
            content_lines[row] = content_lines[row] .. preview
        end
    end
    -- Create a window and display
    if #content_lines == 1 then table.insert(content_lines, '(no marks or notes yet)') end
    local win_bufnr = M.create_window(#content_lines + 1)  -- + the top bar
    MarksMetadata[win_bufnr] = marks_metadata
    vim.api.nvim_buf_set_lines(win_bufnr, 0, -1, false, content_lines)
    -- Put the cursor on the note asked for (after @), else on the mark/note of the line we came from, if any
    local function same_note(a, b)
        return a.type == 'note' and ((b.extmark_id and a.extmark_id == b.extmark_id and a.bufnr == b.bufnr) or (b.id and a.id == b.id))
    end
    local focused = false
    if opt.focus then
        for row = 1, #content_lines do
            if marks_metadata[row] and same_note(marks_metadata[row], opt.focus) then
                vim.api.nvim_win_set_cursor(0, {row, 0})
                focused = true
                break
            end
        end
    end
    for row = focused and math.huge or 1, #content_lines do
        local item = marks_metadata[row]
        local target_path = vim.fn.resolve(vim.api.nvim_buf_get_name(target_bufnr))
        local here = item and (item.type == 'note' and item.bufnr == target_bufnr
            or item.type == 'mark' or item.type == 'global' and vim.fn.resolve(item.path) == target_path)
        if here and item.type ~= 'orphan' and item.row == target_row then
            vim.api.nvim_win_set_cursor(0, {row, 0})
            break
        end
    end
    -- Archived notes all in gray
    for row in pairs(dimmed) do
        vim.api.nvim_buf_set_extmark(win_bufnr, NS_Preview, row-1, 0, {end_row=row-1, end_col=#content_lines[row], hl_group='Comment', priority=200})
    end
    -- Gray the path and line text, kept as real text so `/` search finds them
    for row, start_col in pairs(gray_from) do
        vim.api.nvim_buf_set_extmark(win_bufnr, NS_Preview, row-1, start_col, {
            end_row=row-1, end_col=#content_lines[row], hl_group='Comment', priority=200,
        })
    end
    -- Keys hint in the window's top bar, so it stays visible when the list scrolls
    vim.wo.winbar = '%#Comment#' .. hint:gsub('%%', '%%%%')
    vim.cmd('setlocal nomodifiable')
    -- Show the list from its first line (the section titles above the cursor stay in view); scroll only as much as
    -- needed when the focused row is below the window
    local cursor_row = vim.api.nvim_win_get_cursor(0)[1]
    local top = math.max(1, cursor_row - vim.api.nvim_win_get_height(0) + 1)
    vim.fn.winrestview({topline=top, lnum=cursor_row, col=0})
    -- Show the item under the cursor in the code window as the cursor moves; closing the menu puts it back
    local origin_win = MenuOrigin.win
    Peek = {win=origin_win, bufnr=target_bufnr, view=vim.api.nvim_win_call(origin_win, vim.fn.winsaveview)}
    local peeked_row = nil
    local function peek_cursor()
        local row = vim.api.nvim_win_get_cursor(0)[1]
        if row == peeked_row then return end
        peeked_row = row
        -- Scheduled: CursorMoved isn't nested, so a file opened inside it wouldn't get its BufRead/BufEnter hooks
        vim.schedule(function()
            if vim.api.nvim_buf_is_valid(win_bufnr) and peeked_row == row then peek(marks_metadata[row]) end
        end)
    end
    vim.api.nvim_create_autocmd('CursorMoved', {buffer=win_bufnr, callback=peek_cursor})
    vim.api.nvim_create_autocmd('BufUnload', {buffer=win_bufnr, once=true, callback=end_peek})
    -- Left for another window: the menu closes from inside an autocmd, so BufUnload above doesn't run;
    -- keep what the code window shows, as you went to look at it
    vim.api.nvim_create_autocmd('BufLeave', {buffer=win_bufnr, once=true, callback=function()
        vim.schedule(function()
            if Peek and not vim.api.nvim_buf_is_valid(win_bufnr) then
                Peek.keep = true
                end_peek()
            end
        end)
    end})
    peek_cursor()
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
    vim.keymap.set('n', 'a', function()
        for _, note in ipairs(notes) do
            if note.bufnr == target_bufnr and note.row == target_row then return M.edit_note(note) end
        end
        M.switchEditMode(target_bufnr, target_row)
    end, opts)
    -- Key: next status for the note under the cursor. The list redraws with the note in its new section and the
    -- cursor still on it, so pressing @ again keeps cycling the same note
    vim.keymap.set('n', '@', function()
        local mark = M.get_mark_at_cursor()
        if not (mark and mark.type == 'note') then
            vim.api.nvim_echo({{'Not on a note', 'WarningMsg'}}, false, {})
            return
        end
        local status = M.cycle_status(mark)
        vim.cmd('bwipeout!')
        M.openMarks({focus=mark})
        vim.api.nvim_echo({{'Status: ' .. StatusTitles[status], 'Normal'}}, false, {})
    end, opts)
    -- Start the tour under the cursor in guided mode
    local function start_tour(mark)
        if mark.error then
            vim.api.nvim_echo({{'nvim-marks: ' .. mark.error, 'ErrorMsg'}}, false, {})
            return
        end
        vim.cmd('bwipeout!')  -- back in the code window, then guided mode opens its own panel
        require('nvim-marks.tour_panel').start(mark.path, target_bufnr, function(n) return M.create_window(n, true) end)
    end
    -- Key: Edit the note under the cursor, or start the tour under it (like <CR>)
    vim.keymap.set('n', EditKey, function()
        local mark = M.get_mark_at_cursor()
        if mark and mark.type == 'note' then
            M.edit_note(mark)
        elseif mark and mark.type == 'tour' then
            start_tour(mark)
        else
            vim.api.nvim_echo({{'Not on a note or tour', 'WarningMsg'}}, false, {})
        end
    end, opts)
    -- Key: Jump to mark/note
    vim.keymap.set('n', '<CR>', function()
        local mark = M.get_mark_at_cursor()
        if mark and mark.type == 'tour' then return start_tour(mark) end
        if mark and mark.type == 'orphan' then
            vim.api.nvim_echo({{'Not found in this version of the file', 'WarningMsg'}}, false, {})
        elseif mark then
            if Peek then Peek.keep = true end  -- the code window already shows it, keep it there
            vim.cmd('bwipeout!')
            if mark.type == 'global' then
                vim.cmd('edit ' .. vim.fn.fnameescape(mark.path))
                vim.api.nvim_win_set_cursor(0, {math.min(mark.row, vim.api.nvim_buf_line_count(0)), 0})
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
                local bufnr = mark.type == 'global' and vim.fn.bufadd(mark.path) or target_bufnr
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

--- Move a note to its next status and save it right away (open buffer: via its extmark; closed file: in the store)
---
--- @return string # the new status
function M.cycle_status(note)
    local status = utils.next_status(note.status)
    if note.extmark_id then
        utils.set_note_status(note.bufnr, note.extmark_id, status)
        utils.save_all(note.bufnr)
    else
        utils.edit_stored(note.store_path, note.id, nil, status)
    end
    note.status = status
    return status
end

--- Open a note's file and put the cursor on it (the note may have moved since it was saved)
function M.jump_to_note(note)
    if note.bufnr then
        vim.api.nvim_set_current_buf(note.bufnr)
    elseif note.exists == false then
        -- Don't open an empty buffer at a made-up path
        vim.api.nvim_echo({{'Not found in any checkout of this repo: ' .. note.filename, 'WarningMsg'}}, false, {})
        return
    else
        vim.cmd('edit ' .. vim.fn.fnameescape(note.path))
    end
    local bufnr = vim.api.nvim_get_current_buf()
    vim.api.nvim_win_set_cursor(0, {math.min(M.find_note_row(bufnr, note), vim.api.nvim_buf_line_count(bufnr)), 0})
end

--- @return integer # the note's row in the buffer now, its saved row if it's not found there
function M.find_note_row(bufnr, note)
    for _, item in ipairs(utils.scan_notes(bufnr)) do
        local id, item_row, text = unpack(item)
        if id == note.extmark_id or vim.deep_equal(text, note.text) then return item_row end
    end
    return note.row
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

--- @param content_lines integer|nil # lines to show; the window fits them, between the min and max height
--- @return integer # window height
function M.window_height(content_lines)
    local max = vim.g.nvim_marks_height or 0.4  -- max height: a share of the screen (< 1) or a number of lines
    if max < 1 then max = math.floor(vim.o.lines * max) end
    local min = math.min(10, max)
    return math.max(min, math.min(max, content_lines or max))
end

--- @param content_lines integer|nil # lines it will show, to size the window to them
--- @param keep boolean|nil # stay open when the cursor leaves it (guided mode); default closes on leave
--- @return integer # Mark-window's Buffer id
function M.create_window(content_lines, keep)
    if vim.b.is_marks_window == true then vim.cmd('bwipeout!') end  -- Close existing quick window
    -- One panel at a time: close any other one in this tab, e.g. the tour panel (it stays open when you go to the
    -- code, and closing it ends the tour) when `m` is pressed there
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if win ~= vim.api.nvim_get_current_win() and vim.b[vim.api.nvim_win_get_buf(win)].is_marks_window then
            vim.api.nvim_win_close(win, true)
        end
    end
    -- A scratch buffer from the start: other plugins' BufEnter hooks skip it (no git calls on every open)
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.cmd('botright ' .. M.window_height(content_lines) .. ' split')
    vim.api.nvim_win_set_buf(0, bufnr)
    vim.b.is_marks_window = true
    vim.bo[bufnr].filetype = 'nvim-marks'
    -- Markdown highlighting (titles, `code`, **bold**, links) with treesitter: ~1.5ms, where `filetype=markdown`
    -- loads vim's markdown + html + css syntax files on every open (~10ms). Without the parser, titles only.
    if not pcall(vim.treesitter.start, bufnr, 'markdown') then
        vim.api.nvim_buf_call(bufnr, function()
            vim.cmd([[syntax match NvimMarksTitle /^#.*$/]])
            vim.cmd([[highlight default link NvimMarksTitle Title]])
        end)
    end
    vim.cmd('mapclear <buffer>')
    if not keep then vim.cmd('autocmd BufLeave,BufWinLeave,BufHidden <buffer> ++once  :bd!') end
    vim.cmd('nnoremap <buffer> <silent> <nowait> q :bwipeout!<CR>')
    vim.cmd('nnoremap <buffer> <silent> <nowait> <ESC> :bwipeout!<CR>')
    vim.cmd('setlocal buftype=nofile bufhidden=wipe noswapfile nonumber norelativenumber nowrap nocursorline')
    return vim.api.nvim_get_current_buf()
end

--- Read from user edits, save it to an extmark attached to the target
---
--- @param edit_bufnr integer # editor-buffer's id
--- @param target_bufnr integer|nil # target-buffer's id, nil for a note of a file that isn't open
--- @param on_save function # called with the typed lines
function M.save_note(edit_bufnr, target_bufnr, on_save, _, on_delete)
    local text = vim.api.nvim_buf_get_lines(edit_bufnr, 0, -1, false)
    if not utils.is_empty_note(text) then
        on_save(text)
    elseif on_delete then
        on_delete()  -- an existing note cleared to nothing (or only spaces) is deleted
    end  -- a new note with nothing typed: just close
    if target_bufnr then
        utils.save_all(target_bufnr)  -- to the store right away, so other nvims and scripts see it
        utils.refresh_sign_bar(target_bufnr)
    end
    vim.bo[edit_bufnr].modified = false
    local function close()
        if vim.api.nvim_buf_is_valid(edit_bufnr) then vim.api.nvim_buf_delete(edit_bufnr, {force=true}) end
        vim.cmd('stopinsert!')
    end
    close()
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

--- `:NvimMarksNoteToggle`: show or hide notes' text on their lines (the `*` signs stay). With `!`, hide.
function M.toggleNoteText(hide)
    local show = nil  -- flip
    if hide then show = false end
    local shown = utils.toggle_note_text(show)
    vim.api.nvim_echo({{'nvim-marks: note text ' .. (shown and 'shown' or 'hidden'), 'Normal'}}, false, {})
end

--- @param opt table|nil # {dir=string} folder where marks are saved (see store.lua)
---                         {reload_interval=10} seconds between checks for changes from elsewhere, 0 turns it off
---                         {height=0.4} panel max height: a share of the screen (< 1) or a number of lines; it fits its content up to that
---                         {note_style='inline'|'above'} notes at the end of the line (default) or on lines above it
---                         {note_prefix=string} before an inline note, default '    -- '
---                         {show_note_text=false} start with notes' text hidden, only the `*` sign shows
function M.setup(opt)
    opt = opt or {}
    if opt.note_style then utils.note_style = opt.note_style end
    if opt.note_prefix then utils.note_prefix = opt.note_prefix end
    if opt.show_note_text ~= nil then utils.toggle_note_text(opt.show_note_text) end
    if opt.dir then require('nvim-marks.store').dir_option = opt.dir end
    if opt.reload_interval then M.start_auto_reload(opt.reload_interval * 1000) end
    if opt.height then vim.g.nvim_marks_height = opt.height end
end

M.start_auto_reload((vim.g.nvim_marks_reload_interval or 10) * 1000)


--- Tests: `nvim -l tests/run.lua`
function M.test_fit()
    local function eq(a, b, msg) assert(a == b, msg .. ': expected ' .. vim.inspect(b) .. ', got ' .. vim.inspect(a)) end
    eq(fit('short', 8), 'short   ', 'padded')
    eq(fit('exactly8', 8), 'exactly8', 'fits exactly')
    eq(fit(string.rep('a', 500), 10), string.rep('a', 9) .. '…', 'long text cut with …')
    eq(vim.fn.strdisplaywidth(fit('中文中文中文中文', 7)), 7, 'wide characters still fit the width')
end

return M
