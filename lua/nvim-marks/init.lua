local M = {}  -- Module

function M.setup(opt)
    print('Setup called with options:', vim.inspect(opt))
    -- TODO: handle options (file location, keymaps, etc)
    -- ...
end


local namespace_id = vim.api.nvim_create_namespace('nvim-marks')
local vim_chars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ'
local vim_global_chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'

function M.openMarks()
    local main_bufid = vim.api.nvim_get_current_buf()  --- @type integer
    local row, _ = unpack(vim.api.nvim_win_get_cursor(0))  -- 0: current window_id
    local content_lines = {
        '" Help: Press `a-Z` Add mark | `+` Add note | `-` Delete  | `*` List all | `q` Quit',
    }
    -- Display existing marks
    local marks = list_marks(main_bufid)
    if next(marks) ~= nil then
        table.insert(content_lines, '')
        table.insert(content_lines, 'Marks:')
    end
    for _, item in pairs(marks) do
        table.insert(content_lines, item.display)
    end
    -- Display existing notes
    local notes = list_notes(main_bufid)
    if next(notes) ~= nil then
        table.insert(content_lines, '')
        table.insert(content_lines, 'notes:')
    end
    for _, item in pairs(notes) do
        table.insert(content_lines, item.display)
    end
    local bufid = createWindow()
    vim.api.nvim_buf_set_lines(bufid, 0, -1, false, content_lines)
    vim.cmd('setlocal readonly nomodifiable')
    vim.cmd('redraw')
    -- Manually listen for keypress
    local char = vim.fn.getcharstr()
    if char == "+" then
        M.editNote(main_bufid, row)
    elseif char == '-' then
        M.delMark(main_bufid, row)
    elseif char == '*' then
        M.listGlobalMarks()
    elseif char == 'q' or char == '\3' or char == '\27' then  -- q | <Ctrl-c> | <ESC>
        vim.cmd('bwipeout!')
    elseif string.find(vim_chars, char, 1, true) then
        M.addMark(main_bufid, row, char)
    end
end

function M.addMark(main_bufid, row, char)
    -- Remove global mark from another file
    local old_bufid, old_row, _, _ = unpack(vim.fn.getpos("'"..char))
    if char:match('%u') and old_bufid > 0 and old_row > 0 and old_bufid ~= main_bufid then
        delete_vimmark(old_bufid, old_row)
        delete_extmark(old_bufid, old_row)
    end
    local mark_id = string.byte(char)
    vim.api.nvim_buf_set_extmark(main_bufid, namespace_id, row - 1, 0, {
        id=mark_id,
        end_row=row-1,  -- TODO: allow multi-line mark/note
        end_col=0,
        sign_text=char,
        sign_hl_group='Todo'
    })
    vim.api.nvim_buf_set_mark(main_bufid, char, row, 0, {})
    vim.cmd('bwipeout!')
end

--- Collect both Nvim Extmarks & Vim Marks
---
--- @param bufid integer
--- @return table<string, table> # {char=details}
local function list_marks(bufid)
    local marks = {}
    local filename = vim.api.nvim_buf_get_name(bufid)
    filename = vim.fn.fnamemodify(filename, ":.")
    -- Nvim Extmarks
    local extmarks = vim.api.nvim_buf_get_extmarks(bufid, namespace_id, 0, -1, {details=true})
    for _, ext in ipairs(extmarks) do
        local mark_id, row, col, details = unpack(ext)
        local char = details.sign_text:gsub('%s+', '') or '?'
        if string.find(vim_chars, char, 1, true) ~= nil then
            -- print('ExtMark found: ', name, row+1, col+1, filename)
            local display = string.format("(%s) %s:%d", char, filename, row+1, col+1)
            marks[char] = {name=char, row=row+1, filename=filename, display=display}
        end
    end
    -- Vim global marks A-Z
    for i=1, #vim_global_chars do
        local char = vim_global_chars:sub(i,i)
        local global_bufid, global_row, _, _ = unpack(vim.fn.getpos("'"..char))
        row, col = unpack(vim.api.nvim_buf_get_mark(global_bufid, char))
        if global_row > 0 and marks[char] == nil then
            filename = vim.api.nvim_buf_get_name(global_bufid)
            filename = vim.fn.fnamemodify(filename, ":.")
            local display = string.format("(%s) %s:%d", char, filename, row)
            marks[char] = {name=char, row=row, filename=filename, display=display}
        end
    end
    return marks
end

--- @param bufid integer
--- @return table<string, table> # {char=details}
local function list_notes(bufid)
    local notes = {} -- @type hash_table{}
    local filename = vim.api.nvim_buf_get_name(bufid)
    filename = vim.fn.fnamemodify(filename, ":.")
    local extmarks = vim.api.nvim_buf_get_extmarks(bufid, namespace_id, 0, -1, {details=true})
    for _, ext in ipairs(extmarks) do
        local mark_id, row, col, details = unpack(ext)
        local char = details.sign_text:sub(1, 1) or '?'
        if char == '*' then
            print('Note found: ', mark_id, row+1, filename)
            local name = details.virt_lines and details.virt_lines[1][1][1]:sub(1, 10) or ''
            local display = string.format("* %s:%d %s", filename, row+1, name)
            notes[char] = {name=name, row=row+1, filename=filename, display=display}
        end
    end
    return notes
end

function M.listGlobalMarks()
    print('Listing global marks: TBD')
    -- Source 1: all marks in the `persistent_marks.json`
    -- Source 2: all Vim global marks with registry `A-Z`
end

function M.editNote(main_bufid, row)
    local bufid = createWindow()
    vim.cmd('set filetype=markdown')
    vim.api.nvim_set_option_value('filetype', 'markdown', { buf = bufid })
    vim.api.nvim_buf_set_lines(bufid, 0, -1, false, {
        '# Help: Press `S` edit; `q` Quit; `Ctrl-s` save and quit',
    })
    -- vim.cmd('startinsert')
    vim.keymap.set({'n', 'i', 'v'}, '<C-s>', function() createNote(main_bufid, bufid, row) end, {buffer=true, silent=true, nowait=true })
end

function M.delMark(main_bufid, row)
    delete_extmark(main_bufid, row)
    delete_vimmark(main_bufid, row)
    vim.cmd('bwipeout!')
end

local function delete_extmark(main_bufid, row)
    local extmarks = get_extmarks_by_row(main_bufid, row)
    for _, mark_id in ipairs(extmarks) do
        vim.api.nvim_buf_del_extmark(main_bufid, namespace_id, mark_id)
    end
end

local function delete_vimmark(main_bufid, row)
    local char = get_mark_by_row(main_bufid, row)
    if char ~= '' then
        vim.api.nvim_buf_del_mark(main_bufid, char)
    end
end

--- For simplicity, we don't mix note with marks, they're managed differently
local function createNote(main_bufid, bufid, row)
    print('Saving note at line ', row, ' in buffer ', bufid)
    local text_lines = vim.api.nvim_buf_get_lines(bufid, 0, -1, false)
    local virt_lines = {}
    for _, line in ipairs(text_lines) do
        table.insert(virt_lines, {{line, "Comment"}})
    end
    local mark_id = math.random(1000, 9999)
    vim.api.nvim_buf_set_extmark(main_bufid, namespace_id, row - 1, 0, {
        id=mark_id,  --- @type number
        end_row=row-1,  -- TODO: allow multi-line mark/note
        end_col=0,
        sign_text='*',
        sign_hl_group='Todo',
        virt_lines=virt_lines,
    })
    vim.cmd('stopinsert')
    vim.cmd('bwipeout!')
end

-- @return integer # Buffer id
local function createWindow()
    if vim.b.is_marks_window == true then vim.cmd('bwipeout!') end  -- Close existing quick window
    vim.cmd('botright 10 new')  -- Create new window and jump to the buffer context
    vim.b.is_marks_window = true
    vim.opt_local.buftype = 'nofile'
    vim.cmd('mapclear <buffer>')
    vim.cmd('autocmd BufLeave,BufWinLeave,BufHidden <buffer> ++once  :bd!')
    vim.cmd('nnoremap <buffer> <silent> <nowait> q :bwipeout!<CR>')
    vim.cmd('nnoremap <buffer> <silent> <nowait> <ESC> :bwipeout!<CR>')
    vim.cmd('nnoremap <buffer> <silent> <nowait> <C-c> :bwipeout!<CR>')
    vim.cmd('setlocal buftype=nofile bufhidden=wipe noswapfile nonumber norelativenumber nowrap nocursorline')
    return vim.api.nvim_get_current_buf()
end

--- @return integer[] # {mark_id, mark_id}
local function get_extmarks_by_row(target_bufid, target_row)
    local marks = {}
    local extmarks = vim.api.nvim_buf_get_extmarks(target_bufid, namespace_id, {target_row-1, 0}, {target_row-1, -1}, {details = true})
    for _, ext in ipairs(extmarks) do
        table.insert(marks, ext[1])
    end
    return marks
end

--- @return string # mark_id
local function get_mark_by_row(target_bufid, target_row)
    local marks = {}
    for i=1, #vim_chars do
        local char = vim_chars:sub(i,i)
        local bufid, row
        if char:match('%u') ~= nil then
            bufid, row, _, _ = unpack(vim.fn.getpos("'"..char))
        else
            bufid = target_bufid
            row, _ = unpack(vim.api.nvim_buf_get_mark(target_bufid, char))
        end
        if bufid == target_bufid and row == target_row and row ~= 0 then
            return char
        end
    end
    return ''
end


return M
