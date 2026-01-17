--- NOTE:
--- 1. We use native Vimmarks for marks, we use extmarks for notes
--- 2. We try not to disrupt native vimmarks key bindings, will just forward the keystroke
--- 3. We save all info into one local file involved all code files in the project.
--- 4. For vim global marks (A-Z), the problem is that we cannot restore the mark without opening the file,
---    which is tricky because we don't want to open a buffer which may trigger other plugin reactions.
---    An easier way: we only restore marks upon BufEnter, if user wants to jump to global marks, has to jump from Marks window,
---    so `'A` won't jump until buffer is opened at least once (unless viminfo/shada were enabled)
--- 5. It should only care about the CURRENT BUFFER
---
--- Workflow:
--- 1. User quit vim and open vim, and edit a file for the first time, initially setup buffer, load all marks from persistent
--- 2. User press `m` to open Marks window
--- 3. Window scans all vimmarks, as well as extmarks of current buffer, then display
--- 4. User press `a-Z` to add a mark, then vimmark is added, and window is closed
--- 5. Or user press `-` to delete a mark, then vimmark is added, and window is closed
--- 6. Or user press `+` add a note, then switch window to edit-mode, when user press `ctrl-s`, it creates an extmark, close window
--- 7. User switch to another buffer, all vimmarks/extmarks will be synced to local persistent
--- 8. User switch back to current buffer, nothing changed (won't restore from persistent again)

local M = {}

local NS_Signs = vim.api.nvim_create_namespace('nvim-marks.signs')
local NS_Notes = vim.api.nvim_create_namespace('nvim-marks.notes')
local ValidMarkChars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ'
local BufCache = {}

local function is_real_file(bufnr)
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
--- @return table|nil
local function load_json(json_path)
    local f = io.open(json_path, 'r')
    if not f then return nil end
    local content = f:read("*all")
    f:close()
    return vim.json.decode(content) or {}
end

--- Get global vimmarks only
--- Related: @restore_global_marks()
---
--- @return table[] # list of vimmark details [{char, row, filename, details}, {...}]
local function scan_global_vimmarks()
    local global_marks = {}
    for _, item in ipairs(vim.fn.getmarklist()) do
        local char = item.mark:sub(2,2)
        local bufnr, row, _, _ = unpack(item.pos)
        local filename = vim.fn.fnamemodify(item.file, ":.")
        table.insert(global_marks, {char, row, filename})
    end
    return global_marks
end

--- Get local vimmarks only
---
--- @Related restore_local_marks()
--- @return table[] # list of vimmark details [{char, row, details}, {...}]
local function scan_vimmarks(target_bufnr)
    local vimmarks = {}
    for _, item in ipairs(vim.fn.getmarklist(target_bufnr)) do
        local char = item.mark:sub(2,2)
        local bufnr, row, _, _ = unpack(item.pos)
        if char:match('[a-z]') ~= nil then
            table.insert(vimmarks, {char, row})
        end
    end
    return vimmarks
end

--- Get notes(extmarks) from given buffer
---
--- @Related restore_local_marks()
--- @return table[] # list of extmark details [{mark_id, row, lines}, {...}]
local function scan_notes(bufnr)
    local notes = {}
    local items = vim.api.nvim_buf_get_extmarks(bufnr, NS_Notes, 0, -1, {details=true})
    for _, ext in ipairs(items) do
        -- print('scanned an extmark', vim.inspect(ext))
        local mark_id, row, _, details = unpack(ext)  -- details: vim.api.keyset.set_extmark
        table.insert(notes, {mark_id, row+1, details.virt_lines})
    end
    return notes
end

--- Save global vimmarks and local vimmarks+notes
local function save_all(bufnr)
    -- Save global vimmarks
    local global_marks = scan_global_vimmarks()
    local json_path = make_json_path('vimmarks_global')
    -- print('saving', #global_marks, 'global_marks to ', json_path)
    if #global_marks > 0 then
        save_json(global_marks, json_path)
    else
        os.remove(json_path)
    end
    if bufnr == nil then return end
    -- Save buffer-only vimmarks+notes
    local vimmarks = scan_vimmarks(bufnr)
    local notes = scan_notes(bufnr)
    local data = {vimmarks=vimmarks, notes=notes}
    json_path = make_json_path(BufCache[bufnr].filename)
    -- print('saving marks', #vimmarks, #notes, 'to', json_path)
    if #vimmarks > 0 or #notes > 0 then
        save_json(data, json_path)
    else
        os.remove(json_path) -- Delete empty files if no marks at all
    end
end

--- Scan multiple vimmarks on a given row
---
--- @return string[] #  Signs of Vimmarks
local function get_mark_chars_by_row(target_bufnr, target_row)
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
function set_vimmark(bufnr, char, row)
    vim.api.nvim_buf_set_mark(bufnr, char, row, 0, {})
end

local function delete_vimmark(bufnr, row)
    local markchars = get_mark_chars_by_row(bufnr, row)
    for _, char in ipairs(markchars) do
        vim.api.nvim_buf_del_mark(bufnr, char)
    end
end

local function delete_note(target_bufnr, target_row)
    local notes = scan_notes(target_bufnr)
    for _, item in ipairs(notes) do
        local mark_id, row, _ = unpack(item)
        if row == target_row then
            vim.api.nvim_buf_del_extmark(target_bufnr, NS_Notes, mark_id)
        end
    end
end


--- Related: @scan_global_vimmarks()
local function restore_global_marks()
    local json_path = make_json_path('vimmarks_global')
    local global_marks = load_json(json_path) or {}  --- @type table[] # [{char=a, row=1, filename=abc}, {...}]
    for _, item in ipairs(global_marks) do
        local char, row, filename = unpack(item)
        local bufnr = vim.fn.bufadd(filename)  -- Will not add/load existing buffer but return existing id
        vim.fn.bufload(bufnr)
        vim.api.nvim_buf_set_mark(bufnr, char, row, 0, {})
    end
end

--- @Related scan_vimmarks()
--- @Related scan_notes()
local function restore_local_marks(bufnr)
    local json_path = make_json_path(BufCache[bufnr].filename)
    local data = load_json(json_path) or {vimmarks={}, notes={}}
    -- print('restoring from', json_path, vim.inspect(data))
    -- Restore local vimmarks
    for _, item in ipairs(data['vimmarks'] or {}) do
        local char, row = unpack(item)
        vim.api.nvim_buf_set_mark(bufnr, char, row, 0, {})
    end
    -- Restore local notes
    for _, ext in ipairs(data['notes'] or {}) do
        local mark_id, row, virt_lines = unpack(ext)
        -- print('extracted notes', vim.inspect(ext), virt_lines)
        vim.api.nvim_buf_set_extmark(bufnr, NS_Notes, row, 0, {
            id=mark_id,
            end_row=row,
            end_col=0,
            sign_text='*',
            sign_hl_group='Comment',
            virt_lines_above=true,
            virt_lines=virt_lines,
        })
    end
end

--- @return integer # Mark-window's Buffer id
local function create_window()
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


--- Scan latest vimmarks and update left sign bar
--- Don't use vim native signs like `sign_define/sign_place` because neovim will create extmarks anyways
local function update_sign_column(bufnr)
    local vimmarks = scan_vimmarks(bufnr)  --  mark={char, filename, row}
    vim.api.nvim_buf_clear_namespace(bufnr, NS_Signs, 0, -1)  -- Delete all signs then add each
    -- Local signs
    for _, item in ipairs(vimmarks) do
        local char, row = unpack(item)
        vim.api.nvim_buf_set_extmark(bufnr, NS_Signs, row-1, 0, {
            id=math.random(1000, 9999),
            end_row=row-1,  -- extmark is 0-indexed
            end_col=0,
            sign_text=char,
            sign_hl_group='WarningMsg',
        })
    end
    -- Global signs
    local global_marks = scan_global_vimmarks()  --  mark={char, filename, row}
    -- print('updating global_marks', #global_marks, 'signs for', bufnr)
    for _, item in ipairs(global_marks) do
        local char, row, filename = unpack(item)
        if filename == BufCache[bufnr].filename then
            vim.api.nvim_buf_set_extmark(bufnr, NS_Signs, row-1, 0, {
                id=math.random(1000, 9999),
                end_row=row-1,  -- extmark is 0-indexed
                end_col=0,
                sign_text=char,
                sign_hl_group='WarningMsg',
            })

        end
    end
    -- Notes:
    -- No need, they are extmarks and will display signs already on creation
end

--- Read from user edits, save it to an extmark attached to the target
---
--- @param edit_bufnr integer # editor-buffer's id
--- @param target_bufnr integer # target-buffer's id
--- @param target_row integer # target-buffer's row number
local function save_note(edit_bufnr, target_bufnr, target_row)
    local virt_lines = {}
    local read_lines = vim.api.nvim_buf_get_lines(edit_bufnr, 0, -1, false)
    for _, line in ipairs(read_lines) do
        table.insert(virt_lines, {{line, "Comment"}})
    end
    vim.api.nvim_buf_set_extmark(target_bufnr, NS_Notes, target_row-1, 0, {
        id=math.random(1000, 9999),
        end_row=target_row-1,  -- extmark is 0-indexed
        end_col=0,
        sign_text='*',
        sign_hl_group='WarningMsg',
        virt_lines=virt_lines,
    })
    vim.cmd('bwipeout!')
    vim.cmd('stopinsert!')
    update_sign_column(target_bufnr)
end

--- Swith to note editing mode allows user to type notes
function M.switchEditMode(target_bufnr, target_row)
    local edit_bufnr = create_window()
    vim.api.nvim_buf_set_lines(edit_bufnr, 0, -1, false, {
        '> Help: Press `S` edit; `q` Quit; `Ctrl-s` save and quit',
    })
    vim.keymap.set({'n', 'i', 'v'}, '<C-s>', function() save_note(edit_bufnr, target_bufnr, target_row) end, {buffer=true, silent=true, nowait=true })
end

function M.openMarks()
    local target_bufnr = vim.api.nvim_get_current_buf()
    local target_row, _ = unpack(vim.api.nvim_win_get_cursor(0))  -- 0: current window_id
    -- Prepare content
    local content_lines = {
        '> Help: Press `a-Z` Add mark | `+` Add note | `-` Delete  | `*` List all | `q` Quit',
    }
    -- Render marks
    local vimmarks = scan_vimmarks(target_bufnr)
    -- print('showing vimmarks', vim.inspect(vimmarks))
    if #vimmarks > 0 then
        table.insert(content_lines, '')
        table.insert(content_lines, '--- Marks ---')
    end
    for _, item in ipairs(vimmarks) do
        local char, row = unpack(item)
        local display = string.format("(%s) %s:%d", char, BufCache[target_bufnr].filename, row)
        table.insert(content_lines, display)
    end
    -- Render global marks
    local global_marks = scan_global_vimmarks()
    for _, item in ipairs(global_marks) do
        local char, row, filename = unpack(item)
        local display = string.format("(%s) %s:%d", char, filename, row)
        table.insert(content_lines, display)
    end
    -- Render notes
    local notes = scan_notes(target_bufnr)
    -- print('showing notes', vim.inspect(notes))
    if #notes ~= 0 then
        table.insert(content_lines, '')
        table.insert(content_lines, '--- Notes ---')
    end
    for _, item in ipairs(notes) do
        local _, row, virt_lines = unpack(item)
        -- print(vim.inspect(virt_lines))  -- eg: {{{"line1", "Comment"}, {"line2", "Comment"}}}
        local preview = '' --TODO: --virt_lines or virt_lines[1] or virt_lines[1][1][1]:sub(1, 24)
        local display = string.format("* %s:%d %s", BufCache[target_bufnr].filename, row, preview)
        table.insert(content_lines, display)
    end
    -- Create a window and display
    local win_bufnr = create_window()
    vim.api.nvim_buf_set_lines(win_bufnr, 0, -1, false, content_lines)
    vim.cmd('setlocal readonly nomodifiable')
    vim.cmd('redraw')
    -- Listen for user's next keystroke
    local key = vim.fn.getcharstr()
    vim.cmd('bwipeout!')  -- Close window no matter what
    if key == '-' then
        delete_vimmark(target_bufnr, target_row)
        delete_note(target_bufnr, target_row)
    elseif key == "+" then
        M.switchEditMode(target_bufnr, target_row)
    elseif key == 'q' or key == '\3' or key == '\27' then  -- q | <Ctrl-c> | <ESC>
        -- Do nothing.
    elseif key:match('[a-zA-Z]') then  -- Any other a-zA-Z letter
        set_vimmark(target_bufnr, key, target_row)
    end
    update_sign_column(target_bufnr)
end

function M.getAllMarks()
    local all_marks = vim.fn.getmarklist()
    for _, mark in ipairs(all_marks) do
        local char, pos, filename = unpack(mark)
        print(char, pos, filename, vim.inspect(mark))
    end
end


--- On buffer init(once), restore marks from persistent file
function M.setupBuffer()
    local bufnr = vim.api.nvim_get_current_buf()
    local is_file = is_real_file(bufnr)
    if not is_file then return end
    local filename = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":.")
    if BufCache[bufnr] == nil then
        BufCache[bufnr] = {setup_done=true, filename=filename, is_file=is_file}
        restore_global_marks()
        restore_local_marks(bufnr)
        update_sign_column(bufnr)
        -- Register auto saving/updating logic
        vim.api.nvim_create_autocmd({'BufLeave', 'BufWinLeave', 'BufHidden'}, {
            buffer = bufnr,
            callback = function() save_all(bufnr) end,
        })
        vim.api.nvim_create_autocmd('BufEnter', {
            buffer = bufnr,
            callback = function() update_sign_column(bufnr) end,
        })
    end
end


return M
