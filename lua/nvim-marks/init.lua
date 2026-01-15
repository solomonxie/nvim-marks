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
        '" Help: Press `-` Delete mark| `+` List all  | `e` Add annotation | `q` Quit',
    }
    -- Display existing marks
    local marks = L.getMarks(main_bufid)
    if next(marks) ~= nil then
        table.insert(content_lines, '')
        table.insert(content_lines, 'Marks:')
    end
    for _, item in pairs(marks) do
        table.insert(content_lines, item.display)
    end
    -- Display existing annotations
    local notes = L.getAnnotations(main_bufid)
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
    if char == '-' then
        M.DelMark(main_bufid, row, char)
    elseif char == "e" then
        -- vim.cmd('setlocal modifiable')
        M.editAnnotation(main_bufid, row)
    elseif char == '+' then
        M.listGlobalMarks()
    elseif char == 'q' or char == '\3' or char == '\27' then  -- q | <Ctrl-c> | <ESC>
        vim.cmd('bwipeout!')
    elseif string.find(vim_chars, char, 1, true) then
        M.addMark(main_bufid, row, char)
    end
end


function M.addMark(main_bufid, row, char)
    local mark_id = math.random(10000, 99999)  -- ID is scoped under whole project
    -- Must auto-align Vim marks & Nvim Extmarks to have wider supports (shortcuts, plugins...)
    print('Adding a mark', char, ':', mark_id, ' at line ', row, ' in buffer ', main_bufid)
    -- TODO: replace existing mark if already exists
    vim.api.nvim_buf_set_mark(main_bufid, char, row, 0, {})  -- Vim native mark
    vim.api.nvim_buf_set_extmark(main_bufid, namespace_id, row - 1, 0, {
        id=mark_id,  -- id=byte value of char (avoids duplicates for same char)
        end_row=row-1,  -- TODO: allow multi-line mark/annotation
        end_col=0,
        sign_text=char,
        sign_hl_group='Todo'
    })
    print("ExtMark added: " .. char); vim.cmd('redraw')
    vim.cmd('bwipeout!')
end

function M.DelMark(main_bufid, row, char)
    -- TODO: Find existing mark at current row
    vim.api.nvim_buf_del_extmark(main_bufid, namespace_id, string.byte(char))
    vim.cmd('bwipeout!')
end

-- Collect both Nvim Extmarks & Vim Marks
-- @param bufid number
-- @return hash_table{} # {char=hash_table}
function L.getMarks(bufid)
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
        row, col = unpack(vim.api.nvim_buf_get_mark(bufid, char))
        if row > 0 and marks[char] == nil then
            -- print('Vim Mark found: ', char, row, filename)
            local display = string.format("(%s) %s:%d", char, filename, row)
            marks[char] = {name=char, row=row, filename=filename, display=display}
        end
    end
    print('Collected', #marks, 'marks: ', vim.inspect(marks))
    return marks
end


function L.getAnnotations(bufid)
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
    print('Collected ', #notes, 'notes: ', vim.inspect(notes))
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
        'Hit `i` to edit your annotation here. (Press `<Ctrl-s>` to save and exit)',
    })
    -- vim.cmd('startinsert')
    vim.keymap.set({'n', 'i', 'v'}, '<C-s>', function() L.saveAnnotation(main_bufid, bufid, row) end, {buffer=true, silent=true, nowait=true })
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
    local mark_id = math.random(10000, 99999)  -- ID is scoped under whole project
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


return M
