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

local Namespace = vim.api.nvim_create_namespace('nvim-marks')
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

--- Get vimmarks beyond buffers
---
--- @return table[] # list of vimmark details [{char, row, filename, details}, {...}]
local function scan_vimmarks()
    local vimmarks = {}
    for i=1, #ValidMarkChars do
        local char = ValidMarkChars:sub(i,i)
        local bufnr, row, col, _ = unpack(vim.fn.getpos("'"..char))
        if bufnr == 0 then bufnr = vim.api.nvim_get_current_buf() end  -- Get real bufnr (0 means current)
        if row ~= 0 then
            table.insert(vimmarks, {char, row, BufCache[bufnr].filename})
        end
    end
    return vimmarks
end

--- Get extmarks from current buffer (doesn't need to care about other buffers)
--- @return table[] # list of extmark details [{mark_id, row, filename, details}, {...}]
local function scan_extmarks(bufnr)
    local extmarks = {}
    local items = vim.api.nvim_buf_get_extmarks(bufnr, Namespace, 0, -1, {details=true})
    for _, ext in ipairs(items) do
        local mark_id, row, _, details = unpack(ext)  -- details: vim.api.keyset.set_extmark
        table.insert(extmarks, {mark_id, row, filename, details})
    end
    return extmarks
end

--- Save both vimmarks/extmarks to a persistent file
local function save_all(bufnr)
    -- Save vimmarks
    local vimmarks = scan_vimmarks()
    local vim_path = make_json_path('vimmarks_global')
    save_json(vimmarks, vim_path)
    -- Save extmarks
    local extmarks = scan_extmarks()
    local ext_path = make_json_path(BufCache[bufnr].filename)
    save_json(extmarks, ext_path)
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

--- Create a vimmark
local function delete_vimmark(bufnr, row)
    local markchars = get_mark_chars_by_row(bufnr, row)
    for _, char in ipairs(markchars) do
        vim.api.nvim_buf_del_mark(bufnr, char)
    end
end

--- Restore Vimmarks for all files, only run once.
--- Vimmarks deals both local and global marks,
--- it's complex to deal with it per buffer, or deal together with extmarks(per-buffer-only)
--- so we keep one persistent file for vimmarks globally, then deal with extmarks elsewhere
local function restore_vimmarks(bufnr)
    local json_path = make_json_path('vimmarks_global')
    local vimmarks = load_json(json_path) or {}  --- @type table[] # [{char=a, filename=abc, row=1}, {...}]
    for _, item in ipairs(vimmarks) do
        local char, row, filename = unpack(item)
        -- For Vim global marks at other files, we need to open the file to restore mark,
        -- but that will trigger some BufEnter actions, which user may not like,
        -- so we allow user to customize this behavior
        if filename == BufCache[bufnr].filename then
            vim.api.nvim_buf_set_mark(bufnr, char, row, 0, {})
        elseif vim.g.set_mark_for_unopened_file == 1 then
            -- Open a hidden buffer, get bufnr, then set the mark
            local new_bufnr = vim.fn.bufadd(filename)
            vim.fn.bufload(new_bufnr)
            vim.api.nvim_buf_set_mark(new_bufnr, char, row, 0, {})
        end
    end
end

--- Restore extmarks only for current buffer, only run once.
local function restore_extmarks(bufnr)
    local json_path = make_json_path(BufCache[bufnr].filename)
    local extmarks = load_json(json_path) or {}  --- @type table[] # [{details}, {details}]
    for _, ext in ipairs(extmarks) do
        local mark_id, row, _, details = unpack(ext)
        vim.api.nvim_buf_set_extmark(bufnr, Namespace, row-1, 0, {
            id=mark_id,
            end_row=row-1,  -- extmark is 0-indexed
            end_col=0,
            sign_text='*',
            sign_hl_group='Comment',
            virt_lines_above=true,
            virt_lines=details.virt_lines,
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
function M.updateSignColumn(bufnr)
    local vimmarks = scan_vimmarks()  --  mark={char, filename, row}
    print('updating signs...')
    -- TODO: create/move/delete signs at the bar
    -- local placed_signs = vim.fn.sign_getplaced(bufnr, {group = "*"})
    -- vim.fn.sign_define("MyLetterA", { text = "A", texthl = "Search" })
    -- vim.fn.sign_place(0, "my_group", "MyLetterA", "%", { lnum = 2 })
    -- -- TODO: review AI code
    -- local sign_group = "my_mark_group"
    -- -- 1. Clear existing signs in this group to handle moved/deleted marks
    -- vim.fn.sign_unplace(sign_group, { buffer = bufnr })
    -- for _, mark in ipairs(vimmarks) do
    --     -- Only process marks for the current file
    --     if mark.filename == vim.api.nvim_buf_get_name(bufnr) then
    --         local sign_name = "MarkSign_" .. mark.char
    --         -- 2. Define sign on the fly (Vim handles duplicates gracefully)
    --         vim.fn.sign_define(sign_name, {
    --             text = mark.char,
    --             texthl = "WarningMsg" -- or your preferred highlight
    --         })
    --         -- 3. Place the sign
    --         -- We use the ASCII value of the char as the ID to keep it unique
    --         local sign_id = string.byte(mark.char)
    --         vim.fn.sign_place(sign_id, sign_group, sign_name, bufnr, { lnum = mark.row })
    --     end
    -- end
end

--- Read from user edits, save it to an extmark attached to the target
---
--- @param edit_bufnr integer # editor-buffer's id
--- @param target_bufnr integer # target-buffer's id
--- @param target_row integer # target-buffer's row number
function M.createNote(edit_bufnr, target_bufnr, target_row)
    local virt_lines = {}
    local read_lines = vim.api.nvim_buf_get_lines(edit_bufnr, 0, -1, false)
    for _, line in ipairs(read_lines) do
        table.insert(virt_lines, {{line, "Comment"}})
    end
    local mark_id = math.random(1000, 9999)
    vim.api.nvim_buf_set_extmark(target_bufnr, Namespace, target_row-1, 0, {
        id=mark_id,
        end_row=target_row-1,  -- extmark is 0-indexed
        end_col=0,
        sign_text='*',
        sign_hl_group='TODO',
        virt_lines=virt_lines,
    })
    vim.cmd('bwipeout!')
end

--- Swith to note editing mode allows user to type notes
function M.switchEditMode(target_bufnr, target_row)
    local edit_bufnr = create_window()
    vim.api.nvim_buf_set_lines(edit_bufnr, 0, -1, false, {
        '> Help: Press `S` edit; `q` Quit; `Ctrl-s` save and quit',
    })
    vim.keymap.set({'n', 'i', 'v'}, '<C-s>', function() M.createNote(edit_bufnr, target_bufnr, target_row) end, {buffer=true, silent=true, nowait=true })
end

function M.openMarks()
    local target_bufnr = vim.api.nvim_get_current_buf()
    local target_row, _ = unpack(vim.api.nvim_win_get_cursor(0))  -- 0: current window_id
    -- Prepare content
    local content_lines = {
        '> Help: Press `a-Z` Add mark | `+` Add note | `-` Delete  | `*` List all | `q` Quit',
    }
    -- Render marks
    local vimmarks = scan_vimmarks()
    if next(vimmarks) ~= nil then
        table.insert(content_lines, '')
        table.insert(content_lines, '--- Marks ---')
    end
    print('found #vimmarks', #vimmarks)
    for _, item in ipairs(vimmarks) do
        local char, row, filename = unpack(item)
        local display = string.format("(%s) %s:%d", char, filename, row)
        table.insert(content_lines, display)
    end
    -- Render notes
    local extmarks = scan_extmarks(target_bufnr)
    print('found #extmarks', #extmarks)
    if next(extmarks) ~= nil then
        table.insert(content_lines, '')
        table.insert(content_lines, '--- Notes ---')
    end
    for _, ext in ipairs(extmarks) do
        local _, row, filename, details = unpack(ext)  -- details.virt_lines eg: {{{"line1", "Comment"}, {"line2", "Comment"}}}
        print(vim.inspect(details))
        local preview = details.virt_lines[1][1][1]:sub(1, 24)
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
    elseif key == "+" then
        M.switchEditMode(target_bufnr, target_row)
    elseif key == 'q' or key == '\3' or key == '\27' then  -- q | <Ctrl-c> | <ESC>
        -- Do nothing.
    elseif key:match('%a') then  -- Any other a-zA-Z letter
        set_vimmark(target_bufnr, key, target_row)
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
        restore_vimmarks(bufnr)
        restore_extmarks(bufnr)
        print('Buffer setup done for bufnr:', bufnr)
    end
end


return M
