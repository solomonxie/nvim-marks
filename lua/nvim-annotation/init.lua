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
--     When user add/edit annotation, save the annotation to a file (default to `~/.config/nvim/marks_annotations.json`, but is configuerable)
-- Step5: Implement persistent marks Matching logic
--     When user open a file, load the marks annotations from the file, and use matchinmg algorithm to set the marks



local M = {}

function M.setup(opt)
    print('Setup called with options:', vim.inspect(opt))
    -- TODO
    -- ...
end


local namespace_id = vim.api.nvim_create_namespace('poc_marks')

function openMarks()
    local main_bufid = vim.api.nvim_get_current_buf()  --@type number
    local row, col = unpack(vim.api.nvim_win_get_cursor(0))
    local buf = setupQuickWindow()
    local content_lines = {
        'Marks Menu:',
        '',
        '(a) Add Mark',
        '(d) Delete Mark',
        '(e) Edit Annotation',
        '(l) List Marks',
        '(L) List All Marks',
        '',
        "Press 'q' to close this window."
    }
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, content_lines)
    vim.cmd('setlocal readonly nomodifiable')
    vim.keymap.set('n', 'a', function() addMark(main_bufid, row) end, {buffer=true, silent=true, nowait=true })
    vim.keymap.set('n', 'e', function() editAnnotation(main_bufid) end, {buffer=true, silent=true, nowait=true })
    vim.keymap.set('n', 'l', function() listMarks(main_bufid) end, {buffer=true, silent=true, nowait=true })
    vim.keymap.set('n', 'L', function() listGlobalMarks() end, {buffer=true, silent=true, nowait=true })
end


function addMark(main_bufid, row)
    listMarks(main_bufid)
    local char = vim.fn.getcharstr()  -- Wait for a key press
    local mark_id = math.random(10000, 99999)  -- ID is scoped under whole project
    -- Must auto-align Vim marks & Nvim Extmarks to have wider supports (shortcuts, plugins...)
    print('Adding mark: ', mark_id, ' at line ', row, ' in buffer ', main_bufid)
    vim.api.nvim_buf_set_mark(main_bufid, char, row, 0, {})  -- Vim native mark
    vim.api.nvim_buf_set_extmark(main_bufid, namespace_id, row - 1, 0, {
        id=mark_id,  -- id=byte value of char (avoids duplicates for same char)
        end_row=row - 1,  -- TODO: allow multi-line mark/annotation
        end_col=0,
        sign_text=char,
        sign_hl_group='Todo'
    })
    print("ExtMark added: " .. char)
    vim.cmd('bwipeout!')
end

function DelMark(main_bufid)
    listMarks(main_bufid)
    local char = vim.fn.getcharstr()
    if main_bufid and vim.api.nvim_buf_is_valid(main_bufid) then
        vim.api.nvim_buf_del_extmark(main_bufid, namespace_id, string.byte(char))
        print("ExtMark deleted: " .. char)
    end
    vim.cmd('bwipeout!')
end

function listMarks(main_bufid)
    local content_lines = {'Marks Viewer:', ''}
    local marks = collectMarks(main_bufid)
    -- print('Collected marks: ', vim.inspect(marks))
    for _, meta in pairs(marks) do
        table.insert(content_lines, meta.display)
    end
    local bufid = setupQuickWindow()
    vim.api.nvim_buf_set_lines(bufid, 0, -1, false, content_lines)
    vim.api.nvim_buf_set_lines(bufid, -1, -1, false, {'', 'Press `q` to close this window.'})
    vim.cmd('setlocal readonly nomodifiable')
    vim.cmd('redraw')
end

-- Collect both Vim marks & Nvim extmarks
-- @param bufid number
-- @return hash_table{} # {char=hash_table}
function collectMarks(bufid)
    local marks = {} -- @type hash_table{}
    local filename = vim.api.nvim_buf_get_name(bufid)
    filename = vim.fn.fnamemodify(filename, ":.")
    -- Neovim Extmarks
    local extmarks = vim.api.nvim_buf_get_extmarks(bufid, namespace_id, 0, -1, {details=true})
    for _, ext in ipairs(extmarks) do
        local _, row, col, details = unpack(ext)
        local char = details.sign_text:gsub('%s+', '') or '?'
        print('ExtMark found: ', char, row+1, col+1, filename)
        local display = string.format("(%s) %s:%d", char, filename, row+1, col+1)
        marks[char] = {char=char, row=row+1, filename=filename, display=display}
    end
    -- Vim Marks
    local vim_chars = 'abcdefghijklmnopqrstuvwxyz'
    for i=1, #vim_chars do
        local char = vim_chars:sub(i,i)
        row, col = unpack(vim.api.nvim_buf_get_mark(bufid, char))
        if row > 0 and marks[char] == nil then
            print('Vim Mark found: ', char, row, filename)
            local display = string.format("(%s) %s:%d", char, filename, row)
            marks[char] = {marks, {char=char, row=row, filename=filename, display=display}}
        end
    end
    return marks
end

function listGlobalMarks()
    print('Listing global marks: TBD')
    -- Source 1: all marks in the `persistent_marks.json`
    -- Source 2: all Vim global marks with registry `A-Z`
end

function editAnnotation(main_bufid)
    local bufid = setupQuickWindow()
    vim.api.nvim_buf_set_lines(bufid, 0, -1, false, {
        '-- Enter your annotation here.',
        'Press `<Ctrl-s>` to save and exit --',
    })
    vim.cmd('startinsert')
    vim.keymap.set({'n', 'i', 'v'}, '<C-s>', function() saveAnnotation(main_bufid, bufid) end, {buffer=true, silent=true, nowait=true })
end

function saveAnnotation(main_bufid, bufid)
    local all_lines = vim.api.nvim_buf_get_lines(bufid, 0, -1, false)
    local text = table.concat(all_lines, "\n")
    print('Annotation saved: \n' .. text)
    vim.cmd('stopinsert')
    vim.cmd('bwipeout!')
    listMarks(main_bufid)
end

-- @return integer # Buffer id
function setupQuickWindow()
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


print('Loaded init.lua')
return M
