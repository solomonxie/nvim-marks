-- Step1: UI/UX
-- User hit `m`, pops a bottom split window shows these options: (a) add mark, (d) delete mark, (l) list marks, (Enter) add annotation
-- (a) Add mark: show a list of existing marks, allow user to type a char to add/replace a mark at current location,
--               this is a trade-off of changing native behavior of `m{char}` to `ma{char}`, but I think it's more intuitive.
-- (d) Delete mark: show a list of existing marks, allow user to type a char to delete
-- (Enter) Add annotation: pop window is changed to an empty mutable buffer allow user to add annotation
-- Step2: Implement marks listing logic
--     When user hit (l) List marks: pop a bottom split window shows all marks in
-- Step3: Implement jump logic
--      User can navigate to a mark by selecting it in the list (press Enter), or typing
-- Step4: Implement persistent marks Saving logic
--     When user add/edit annotation, save the annotation to a file (default to `~/.config/nvim/persistent_marks.json`, but is configuerable)
-- Step5: Implement persistent marks Matching logic
--     When user open a file, load the marks annotations from the file, and use matchinmg algorithm to set the marks



local M = {}
local L = {}

function M.setup(opt)
    print('Setup called with options:', vim.inspect(opt))
    -- TODO: handle options (file location, keymaps, etc)
    -- ...
end


local namespace_id = vim.api.nvim_create_namespace('nvim-marks')
local vim_chars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ'
local vim_global_chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'

function M.openMarks()
    local main_bufid = vim.api.nvim_get_current_buf()  --@type number
    local row, _ = unpack(vim.api.nvim_win_get_cursor(0))  -- 0: current window_id
    local content_lines = {
        '" Help: Press `a-Z` Add mark | `e` Add annotation | `d` Delete  | `l` List all | `q` Quit',
    }
    -- Display existing marks
    local marks = L.list_marks(main_bufid)
    if next(marks) ~= nil then
        table.insert(content_lines, '')
        table.insert(content_lines, 'Marks:')
    end
    for _, item in pairs(marks) do
        table.insert(content_lines, item.display)
    end
    -- Display existing annotations
    local notes = L.list_annotations(main_bufid)
    if next(notes) ~= nil then
        table.insert(content_lines, '')
        table.insert(content_lines, 'Annotations:')
    end
    for _, item in pairs(notes) do
        table.insert(content_lines, item.display)
    end
    local bufid = L.createWindow()
    vim.api.nvim_buf_set_lines(bufid, 0, -1, false, content_lines)
    vim.cmd('setlocal readonly nomodifiable')
    vim.cmd('redraw')
    -- Manually listen for keypress
    local char = vim.fn.getcharstr()
    if char == "e" then
        M.editAnnotation(main_bufid, row)
    elseif char == 'd' then
        M.delMark(main_bufid, row)
    elseif char == 'l' then
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
        print('Deleting global mark before adding new', char)
        L.delete_vimmark(old_bufid, old_row)
        L.delete_extmark(old_bufid, old_row)
    end
    local mark_id = string.byte(char)
    vim.api.nvim_buf_set_extmark(main_bufid, namespace_id, row - 1, 0, {
        id=mark_id,
        end_row=row-1,  -- TODO: allow multi-line mark/annotation
        end_col=0,
        sign_text=char,
        sign_hl_group='Todo'
    })
    vim.api.nvim_buf_set_mark(main_bufid, char, row, 0, {})
    vim.cmd('bwipeout!')
end

function M.toggleMark_old(main_bufid, row, char)
    -- NOTE: If multiple chars associated, only delete the given char
    local extmarks = vim.api.nvim_buf_get_extmarks(main_bufid, namespace_id, {row - 1, 0}, {row - 1, -1}, {details = true})
    local existed = false
    for _, ext in ipairs(extmarks) do
        local mark_id, _, _, details = unpack(ext)
        local c = details.sign_text:sub(1, 1) or '?'
        if c == char then
            vim.api.nvim_buf_del_extmark(main_bufid, namespace_id, mark_id)
            vim.api.nvim_buf_del_mark(main_bufid, char)
            existed = true
            break
        end
    end
    if not existed then
        local mark_id = string.byte(char)
        vim.api.nvim_buf_set_extmark(main_bufid, namespace_id, row - 1, 0, {
            id=mark_id,  -- id=byte value of char (avoids duplicates for same char)
            end_row=row-1,  -- TODO: allow multi-line mark/annotation
            end_col=0,
            sign_text=char,
            sign_hl_group='Todo'
        })
        vim.api.nvim_buf_set_mark(main_bufid, char, row, 0, {})
    end
    vim.cmd('bwipeout!')
end

-- Collect both Nvim Extmarks & Vim Marks
-- @param bufid number
-- @return hash_table{} # {char=hash_table}
function L.list_marks(bufid)
    local marks = {} -- @type hash_table{}
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

function L.list_annotations(bufid)
    local notes = {} -- @type hash_table{}
    local filename = vim.api.nvim_buf_get_name(bufid)
    filename = vim.fn.fnamemodify(filename, ":.")
    local extmarks = vim.api.nvim_buf_get_extmarks(bufid, namespace_id, 0, -1, {details=true})
    for _, ext in ipairs(extmarks) do
        local mark_id, row, col, details = unpack(ext)
        local char = details.sign_text:sub(1, 1) or '?'
        if char == '*' then
            print('Annotation found: ', mark_id, row+1, filename)
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

function M.editAnnotation(main_bufid, row)
    local bufid = L.createWindow()
    vim.cmd('set filetype=markdown')
    vim.api.nvim_set_option_value('filetype', 'markdown', { buf = bufid })
    vim.api.nvim_buf_set_lines(bufid, 0, -1, false, {
        '# Help: Press `C` edit; `q` Quit; `Ctrl-s` save and quit',
    })
    -- vim.cmd('startinsert')
    vim.keymap.set({'n', 'i', 'v'}, '<C-s>', function() L.saveAnnotation(main_bufid, bufid, row) end, {buffer=true, silent=true, nowait=true })
end

function M.delMark(main_bufid, row)
    L.delete_extmark(main_bufid, row)
    L.delete_vimmark(main_bufid, row)
    vim.cmd('bwipeout!')
end

function L.delete_extmark(main_bufid, row)
    local extmarks = L.get_extmarks_by_row(main_bufid, row)
    for _, mark_id in ipairs(extmarks) do
        vim.api.nvim_buf_del_extmark(main_bufid, namespace_id, mark_id)
    end
end

function L.delete_vimmark(main_bufid, row)
    local char = L.get_mark_by_row(main_bufid, row)
    if char ~= nil then
        vim.api.nvim_buf_del_mark(main_bufid, char)
    end
end

function L.saveAnnotation(main_bufid, bufid, row)
    -- NOTE: For simplicity, we don't mix annotation with marks, they're managed differently
    -- TODO: maybe put notes in diagnostics instead of extmarks?
    print('Saving annotation at line ', row, ' in buffer ', bufid)
    local text_lines = vim.api.nvim_buf_get_lines(bufid, 0, -1, false)
    local virt_lines = {}
    for _, line in ipairs(text_lines) do
        table.insert(virt_lines, {{line, "Comment"}})
    end
    -- TODO: Save annotation to Extmarks
    local mark_id = math.random(1000, 9999)
    vim.api.nvim_buf_set_extmark(main_bufid, namespace_id, row - 1, 0, {
        id=mark_id,  -- @type number
        end_row=row-1,  -- TODO: allow multi-line mark/annotation
        end_col=0,
        sign_text='*',
        sign_hl_group='Todo',
        virt_lines=virt_lines,
    })
    print('Annotation saved: ', text)
    vim.cmd('stopinsert')
    vim.cmd('bwipeout!')
end

-- @return integer # Buffer id
function L.createWindow()
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

-- @return array {mark_id, mark_id}
function L.get_extmarks_by_row(bufid, target_row)
    -- Parameters: (buffer, namespace, start_pos, end_pos, options)
    local marks = {}
    local extmarks = vim.api.nvim_buf_get_extmarks(bufid, namespace_id, {target_row-1, 0}, {target_row-1, -1}, {details = true})
    for _, ext in ipairs(extmarks) do
        table.insert(marks, ext[1])
    end
    return marks
end

-- @return number mark_id
function L.get_mark_by_row(target_bufid, target_row)
    -- Parameters: (buffer, namespace, start_pos, end_pos, options)
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
    return nil
end


return M
