local M = {}  -- Module to be required from outside

local NamespaceID = vim.api.nvim_create_namespace('nvim-marks')
local ValidMarkChars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ'
local ValidGlobalChars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'
local BVars = {}  --- @type table <integer, table> # {bufid=table_of_variables} Buffer scoped variables


--- @param bufid integer
--- @return table<string, table> # {char=details}
local function list_marks(bufid)
    local marks = {}  --- @type table<string, table}
    local filename = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufid), ":.")
    -- Nvim Extmarks
    local extmarks = vim.api.nvim_buf_get_extmarks(bufid, NamespaceID, 0, -1, {details=true})
    for _, ext in ipairs(extmarks) do
        local mark_id, row, col, details = unpack(ext)
        local char = details.sign_text:gsub('%s+', '') or '?'
        if string.find(ValidMarkChars, char, 1, true) ~= nil then
            -- print('ExtMark found: ', name, row+1, col+1, filename)
            local display = string.format("(%s) %s:%d", char, filename, row+1, col+1)
            marks[char] = {name=char, row=row+1, filename=filename, display=display}
        end
    end
    -- Vim global marks A-Z
    for i=1, #ValidGlobalChars do
        local char = ValidGlobalChars:sub(i,i)
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
    local filename = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufid), ":.")
    local extmarks = vim.api.nvim_buf_get_extmarks(bufid, NamespaceID, 0, -1, {details=true})
    for _, ext in ipairs(extmarks) do
        local mark_id, row, col, details = unpack(ext)
        local char = details.sign_text:sub(1, 1) or '?'
        if char == '*' then
            print('Note found: ', mark_id, row+1, filename)
            local name = tostring(mark_id)
            local content = details.virt_lines
            local preview = details.virt_lines and details.virt_lines[1][1][1]:sub(1, 10) or ''
            local display = string.format("* %s:%d %s", filename, row+1, preview)
            notes[name] = {name=name, row=row+1, filename=filename, display=display, content=content}
        end
    end
    return notes
end

--- @return integer # Buffer id
local function createWindow()
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

--- @return integer[] # {mark_id, mark_id}
local function get_extmarks_by_row(target_bufid, target_row)
    local marks = {}
    local extmarks = vim.api.nvim_buf_get_extmarks(target_bufid, NamespaceID, {target_row-1, 0}, {target_row-1, -1}, {details = true})
    for _, ext in ipairs(extmarks) do
        table.insert(marks, ext[1])
    end
    return marks
end

--- @return string # mark_id
local function get_mark_by_row(target_bufid, target_row)
    local marks = {}
    for i=1, #ValidMarkChars do
        local char = ValidMarkChars:sub(i,i)
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

local function delete_extmark(main_bufid, row)
    local extmarks = get_extmarks_by_row(main_bufid, row)
    for _, mark_id in ipairs(extmarks) do
        vim.api.nvim_buf_del_extmark(main_bufid, NamespaceID, mark_id)
    end
end

local function delete_vimmark(main_bufid, row)
    local char = get_mark_by_row(main_bufid, row)
    if char ~= '' then
        vim.api.nvim_buf_del_mark(main_bufid, char)
    end
end

local function is_real_file(bufid)
    if type(bufid) ~= 'number' or not vim.api.nvim_buf_is_valid(bufid) then
        return false
    end
    local buftype = vim.api.nvim_get_option_value("buftype", { buf = bufid })
    if buftype ~= '' then
        return false
    end
    local path = vim.api.nvim_buf_get_name(bufid)
    if path == '' then
        return false
    end
    return vim.fn.filereadable(path) == 1
end

--- Marks go with project, better to be saved under project folder
--- Each file has its own persistent-marks file, just like vim `undofile`
--- TODO: accept customization of main folder instead of `.git/`
---
--- @param source_path string # target buffer's file full path
--- @return string # converted final json path for the persistent marks
local function make_json_path(source_path)
    local flatten_name = vim.fn.fnamemodify(source_path, ':.'):gsub('/', '__'):gsub('\\', '__')
    local proj_root = vim.fs.root(source_path, '.git')
    if not proj_root then proj_root = '/tmp' end
    local proj_name = vim.fn.fnamemodify(proj_root, ':t')
    local json_path = proj_root .. '/.git/persistent_marks/' .. proj_name .. '/' .. flatten_name .. '.json'
    return json_path
end

--- @param data table
local function save_json(data, json_path)
    local json_data = vim.fn.json_encode(data)
    -- Create folder if not exist
    local target_dir = vim.fn.fnamemodify(json_path, ':p:h')
    if vim.fn.isdirectory(target_dir) == 0 then
        vim.fn.mkdir(target_dir, 'p')
    end
    local f = io.open(json_path, 'w')
    if f then
        f:write(json_data)
        f:close()
    else
        print('Failed to write data to', json_path)
    end
end

--- @param json_path string
local function load_json(json_path)
    local f = io.open(json_path, 'r')
    if not f then return nil end
    local content = f:read("*all")
    f:close()
    return vim.json.decode(content)
end

function M.openMarks()
    local main_bufid = vim.api.nvim_get_current_buf()  --- @type integer
    local row, _ = unpack(vim.api.nvim_win_get_cursor(0))  -- 0: current window_id
    local content_lines = {
        '# Help: Press `a-Z` Add mark | `+` Add note | `-` Delete  | `*` List all | `q` Quit',
    }
    -- Display existing marks
    local marks = list_marks(main_bufid)
    if next(marks) ~= nil then
        table.insert(content_lines, '')
        table.insert(content_lines, '--- Marks ---')
    end
    for _, item in pairs(marks) do
        table.insert(content_lines, item.display)
    end
    -- Display existing notes
    local notes = list_notes(main_bufid)
    if next(notes) ~= nil then
        table.insert(content_lines, '')
        table.insert(content_lines, '--- Notes ---')
    end
    for _, item in pairs(notes) do
        table.insert(content_lines, item.display)
    end
    -- Render window content
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
    elseif string.find(ValidMarkChars, char, 1, true) then
        M.addMark(main_bufid, row, char)
    end
end

--- Add both Vim Mark & Neovim Extmark at current line
function M.addMark(main_bufid, row, char)
    -- Remove global mark from another file
    local old_bufid, old_row, _, _ = unpack(vim.fn.getpos("'"..char))
    if char:match('%u') and old_bufid > 0 and old_row > 0 and old_bufid ~= main_bufid then
        delete_vimmark(old_bufid, old_row)
        delete_extmark(old_bufid, old_row)
    end
    local mark_id = string.byte(char)
    -- Add nvim extmark
    vim.api.nvim_buf_set_extmark(main_bufid, NamespaceID, row - 1, 0, {
        id=mark_id,
        end_row=row-1,  -- TODO: allow multi-line mark/note
        end_col=0,
        sign_text=char,
        sign_hl_group='Todo',
    })
    -- Add vim native mark
    vim.api.nvim_buf_set_mark(main_bufid, char, row, 0, {})
    -- Save
    local filename = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(main_bufid), ":.")
    local display = string.format("(%s) %s:%d", char, filename, row+1)
    BVars[main_bufid].Marks[char] = {name=char, row=row+1, filename=filename, display=display}
    M.saveMarks(main_bufid)
    vim.cmd('bwipeout!')
end

function M.listGlobalMarks()
    print('Listing global marks: TBD')
    -- Source 1: all marks in the `persistent_marks.json`
    -- Source 2: all Vim global marks with registry `A-Z`
end

function M.editNote(main_bufid, row)
    -- TOOD: if note already exists at this row, edit instead of create
    local bufid = createWindow()
    vim.api.nvim_set_option_value('filetype', 'markdown', { buf = bufid })
    vim.api.nvim_buf_set_lines(bufid, 0, -1, false, {
        '# Help: Press `S` edit; `q` Quit; `Ctrl-s` save and quit',
    })
    -- vim.cmd('startinsert')
    vim.keymap.set({'n', 'i', 'v'}, '<C-s>', function() M.addNote(main_bufid, bufid, row) end, {buffer=true, silent=true, nowait=true })
end

function M.delMark(main_bufid, row)
    delete_extmark(main_bufid, row)
    delete_vimmark(main_bufid, row)
    vim.cmd('bwipeout!')
end

--- For simplicity, we don't mix note with marks, they're managed differently
function M.addNote(main_bufid, bufid, row)
    print('Saving note at line ', row, ' in buffer ', bufid)
    local text_lines = vim.api.nvim_buf_get_lines(bufid, 0, -1, false)
    local virt_lines = {}
    for _, line in ipairs(text_lines) do
        table.insert(virt_lines, {{line, "Comment"}})
    end
    local mark_id = math.random(1000, 9999)
    vim.api.nvim_buf_set_extmark(main_bufid, NamespaceID, row - 1, 0, {
        id=mark_id,  --- @type number
        end_row=row-1,  -- TODO: allow multi-line mark/note
        end_col=0,
        sign_text='*',
        sign_hl_group='Todo',
        virt_lines=virt_lines,
    })
    -- Save
    local name = tostring(mark_id)
    local content = details.virt_lines
    local preview = details.virt_lines and details.virt_lines[1][1][1]:sub(1, 10) or ''
    local display = string.format("* %s:%d %s", filename, row+1, preview)
    BVars[main_bufid].Notes[char] = {name=name, row=row+1, filename=filename, display=display, content=content}
    M.saveMarks(main_bufid)
    vim.cmd('stopinsert')
    vim.cmd('bwipeout!')
end

--- Collect marks/notes from current buffer and save to a local file
--- Triggered by schedule, BufLeave|VimLeave or manually
---
--- @param bufid integer # target buffer id
function M.saveMarks(bufid)
    marks = vim.deepcopy(BVars[bufid].Marks)
    notes = vim.deepcopy(BVars[bufid].Notes)
    if marks == {} and notes == {} then
        return
    end
    local source_path = vim.api.nvim_buf_get_name(bufid)
    local json_path = make_json_path(source_path)
    local data = {path = source_path, marks = marks, notes = notes}
    save_json(data, json_path)
end

--- Restore marks/notes from the local file to current buffer
--- Triggered by schedule, BufEnter or manually
function M.loadMarks()
    local main_bufid = vim.api.nvim_get_current_buf()
    if not is_real_file(main_bufid) then
        print('buffer isnt real', main_bufid)
        return
    end
    local source_path = vim.api.nvim_buf_get_name(main_bufid)
    local json_path = make_json_path(source_path)
    if vim.fn.filereadable(json_path) == 0 then
        return
    end
    local data = load_json(json_path)
    if data == nil or data.notes == nil then
        return
    end
    -- Load marks
    for char, details in pairs(data.marks) do
        vim.api.nvim_buf_set_extmark(main_bufid, NamespaceID, details.row, 0, {
            id=string.byte(char),
            end_row=details.row,
            end_col=0,
            sign_text=char,
            sign_hl_group='Todo',
        })  -- Neovim
        vim.api.nvim_buf_set_mark(main_bufid, char, details.row, 0, {})  -- Vim
    end
    -- Load notes
    for name, details in pairs(data.notes) do
        print('Recovering one mark', char, vim.inspect(details))
        vim.api.nvim_buf_set_extmark(main_bufid, NamespaceID, details.row, 0, {
            id=tonumber(name),
            end_row=details.row,
            end_col=0,
            sign_text=char,
            sign_hl_group='Todo',
            virt_lines=details.content,
        })
    end
end

function M.bufferSetup(opt)
    -- Setup buffer variables
    local main_bufid = vim.api.nvim_get_current_buf()
    if BVars[main_bufid] == nil then
        BVars[main_bufid] = {Marks={}, Notes={}}
    end
    if BVars[main_bufid].Marks == nil then
        BVars[main_bufid].Marks = {}
    end
    if BVars[main_bufid].Notes == nil then
        BVars[main_bufid].Notes = {}
    end
    M.loadMarks()
    print('buffer setup done')
end

function M.setup(opt)
    print('Setup called with options:', vim.inspect(opt))
    -- TODO: handle options (file location, keymaps, etc)
    -- ...
end

return M
