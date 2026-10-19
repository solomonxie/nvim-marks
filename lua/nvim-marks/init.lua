--- NOTE:
--- 1. We use native Vimmarks for marks, we use extmarks for notes
--- 2. We try not to disrupt native vimmarks key bindings, will just forward the keystroke
--- 3. We save all info into one file per repo (shared by its worktrees), see store.lua; lines are re-found with anchor.lua
--- 4. For vim global marks (A-Z), the problem is that we cannot restore the mark without opening the file,
---    which is tricky because we don't want to open a buffer which may trigger other plugin reactions.
---    An easier way: we only restore marks upon BufEnter, if user wants to jump to global marks, has to jump from Marks window,
---    so `'A` won't jump until buffer is opened at least once (unless viminfo/shada were enabled)
--- 5. It should only care about the CURRENT BUFFER

local M = {}

local utils = require('nvim-marks.utils')

local IsBufferSetup = {}
local NS_Preview = vim.api.nvim_create_namespace('nvim-marks.preview')
local NS_Placeholder = vim.api.nvim_create_namespace('nvim-marks.placeholder')
local MenuKeys = 'qjk'  -- letters the menu uses itself, so they can't be added as marks from it
local ValidMarkChars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ'
local NoteWidth = 40  -- notes column in the menu is as wide as the longest note, up to this; longer ones are cut with `…`
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

--- @return table # gray `>> path:row  "line text"` chunks shown after a note in the menu
local function note_tail(location, path_width, line_text)
    local chunks = {{' >> ' .. fit(location, path_width), 'Comment'}}
    if line_text ~= '' then table.insert(chunks, {'  "' .. line_text:sub(1, 80) .. '"', 'Comment'}) end
    return chunks
end


--- Swith to note editing mode allows user to type notes, starts in insert mode with a placeholder hint
function M.switchEditMode(target_bufnr, target_row)
    local edit_bufnr = M.create_window()
    local function show_placeholder()
        vim.api.nvim_buf_clear_namespace(edit_bufnr, NS_Placeholder, 0, -1)
        local lines = vim.api.nvim_buf_get_lines(edit_bufnr, 0, -1, false)
        if #lines == 1 and lines[1] == '' then
            vim.api.nvim_buf_set_extmark(edit_bufnr, NS_Placeholder, 0, 0, {
                virt_text={{'Type a note | `Ctrl-s`/`Ctrl-c` save and quit | `q` (normal mode) quit', 'Comment'}},
                virt_text_pos='overlay',
            })
        end
    end
    show_placeholder()
    vim.api.nvim_create_autocmd({'TextChanged', 'TextChangedI'}, {buffer=edit_bufnr, callback=show_placeholder})
    for _, key in ipairs({'<C-s>', '<C-c>'}) do
        vim.keymap.set({'n', 'i', 'v'}, key, function() M.save_note(edit_bufnr, target_bufnr, target_row) end, {buffer=true, silent=true, nowait=true })
    end
    vim.cmd('startinsert')
end

function M.openMarks()
    local target_bufnr = vim.api.nvim_get_current_buf()
    local target_row, _ = unpack(vim.api.nvim_win_get_cursor(0))  -- 0: current window_id
    local filename = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(target_bufnr), ":.")
    -- Prepare content
    local content_lines = {
        '> Help: Press a letter to add that mark (not ' .. MenuKeys .. ') | `-` Delete (y/n) | `+` Add note | `<CR>` Jump | `q` Quit',
    }
    local previews = {}  -- {window_row: line text}, shown in gray after each item
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
    -- Render notes
    local notes = utils.scan_notes(target_bufnr)
    if #notes ~= 0 then
        table.insert(content_lines, '')
        table.insert(content_lines, '# Notes')
    end
    local note_width = column_width(vim.tbl_map(function(item) return note_summary(item[3]) end, notes), NoteWidth)
    local path_width = column_width(vim.tbl_map(function(item) return filename .. ':' .. item[2] end, notes), PathWidthMax)
    for _, item in ipairs(notes) do
        local id, row, note_lines = unpack(item)
        table.insert(content_lines, '* ' .. fit(note_summary(note_lines), note_width))
        previews[#content_lines] = note_tail(filename .. ':' .. row, path_width, utils.line_preview(target_bufnr, row))
        marks_metadata[#content_lines] = { type = 'note', id = id, row = row, filename = filename }
    end
    -- Render orphans: saved marks/notes whose line isn't in this version of the file (e.g. another branch)
    local orphans = utils.Orphans[target_bufnr] or {}
    if #orphans ~= 0 then
        table.insert(content_lines, '')
        table.insert(content_lines, '# Not found in this version (kept until deleted)')
    end
    local function orphan_label(item) return item.char and ('(' .. item.char .. ')') or ('* ' .. note_summary(item.text)) end
    local orphan_width = column_width(vim.tbl_map(orphan_label, orphans), NoteWidth + 2)
    local orphan_path_width = column_width(vim.tbl_map(function(item) return filename .. ':' .. item.anchor.row end, orphans), PathWidthMax)
    for i, item in ipairs(orphans) do
        table.insert(content_lines, fit(orphan_label(item), orphan_width))
        previews[#content_lines] = note_tail(filename .. ':' .. item.anchor.row, orphan_path_width, vim.trim(item.anchor.line))
        marks_metadata[#content_lines] = { type = 'orphan', index = i, char = item.char, row = item.anchor.row, filename = filename }
    end
    -- Create a window and display
    local win_bufnr = M.create_window()
    MarksMetadata[win_bufnr] = marks_metadata
    vim.api.nvim_buf_set_lines(win_bufnr, 0, -1, false, content_lines)
    -- Put the cursor on the mark/note of the line we came from, if any
    for row = 1, #content_lines do
        local item = marks_metadata[row]
        if item and item.type ~= 'orphan' and item.row == target_row and item.filename == filename then
            vim.api.nvim_win_set_cursor(0, {row, 0})
            break
        end
    end
    for row, preview in pairs(previews) do
        local chunks = type(preview) == 'table' and preview or {{'  ' .. preview:sub(1, 80), 'Comment'}}
        if preview ~= '' then
            vim.api.nvim_buf_set_extmark(win_bufnr, NS_Preview, row-1, 0, {virt_text=chunks})
        end
    end
    -- Help line in gray, over the markdown highlighting
    vim.api.nvim_buf_set_extmark(win_bufnr, NS_Preview, 0, 0, {end_row=1, hl_group='Comment', hl_eol=true, priority=200})
    vim.cmd('setlocal nomodifiable')
    -- Key: any letter adds that mark, except the menu's own keys
    local opts = { buffer = win_bufnr, silent = true, nowait = true }
    for char in (ValidMarkChars:gsub('[' .. MenuKeys .. ']', '')):gmatch('.') do
        vim.keymap.set('n', char, function()
            utils.set_vimmark(target_bufnr, char, target_row)
            utils.refresh_sign_bar(target_bufnr)
            vim.cmd('bwipeout!')
            vim.api.nvim_echo({{'Added mark: '..char, 'Normal'}}, false, {})
        end, opts)
    end
    -- Key: Add a note
    vim.keymap.set('n', '+', function()
        M.switchEditMode(target_bufnr, target_row)
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
            elseif mark.type == 'note' then
                vim.api.nvim_buf_del_extmark(target_bufnr, utils.NS_Notes, mark.id)
                utils.refresh_sign_bar(target_bufnr)
            elseif mark.type == 'orphan' then
                utils.delete_orphan(target_bufnr, mark.index)
            end
            vim.cmd('bwipeout!')
            vim.api.nvim_echo({{'Deleted ' .. mark.type .. ': ' .. (mark.char or mark.id), 'Normal'}}, false, {})
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
--- @param target_bufnr integer # target-buffer's id
--- @param target_row integer # target-buffer's row number
function M.save_note(edit_bufnr, target_bufnr, target_row)
    local text = vim.api.nvim_buf_get_lines(edit_bufnr, 0, -1, false)
    if vim.trim(table.concat(text, '\n')) ~= '' then  -- Nothing typed: just close
        utils.set_note(target_bufnr, target_row, text)
    end
    vim.cmd('bwipeout!')
    vim.cmd('stopinsert!')
    utils.refresh_sign_bar(target_bufnr)
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


--- @param opt table|nil # {dir=string} folder where marks are saved (see store.lua)
---                         {note_style='inline'|'above'} notes at the end of the line (default) or on lines above it
---                         {note_prefix=string} before an inline note, default '    -- '
function M.setup(opt)
    opt = opt or {}
    if opt.note_style then utils.note_style = opt.note_style end
    if opt.note_prefix then utils.note_prefix = opt.note_prefix end
    if opt.dir then require('nvim-marks.store').dir_option = opt.dir end
end

return M
