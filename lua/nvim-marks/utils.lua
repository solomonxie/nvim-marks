local M = {}

local NS_Signs = vim.api.nvim_create_namespace('nvim-marks.signs')
local NS_Notes = vim.api.nvim_create_namespace('nvim-marks.notes')
local ValidMarkChars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ'
local GitBlameCache = {}  --- @type table{string, table}  # {filename={blame_tuple}}

function M.is_real_file(bufnr)
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
function M.make_json_path(source_path)
    local flatten_name = vim.fn.fnamemodify(source_path, ':.'):gsub('/', '__'):gsub('\\', '__')
    local proj_root = vim.fs.root(source_path, '.git')
    if not proj_root then proj_root = '/tmp' end
    local proj_name = vim.fn.fnamemodify(proj_root, ':t')
    local json_path = proj_root .. '/.git/persistent_marks/' .. proj_name .. '/' .. flatten_name .. '.json'
    return json_path
end

--- @param data table
function M.save_json(data, json_path)
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
function M.load_json(json_path)
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
function M.scan_global_vimmarks()
    local global_marks = {}
    for _, item in ipairs(vim.fn.getmarklist()) do
        local char = item.mark:sub(2,2)
        local bufnr, row, _, _ = unpack(item.pos)
        local filename = vim.fn.fnamemodify(item.file, ":.")
        if GitBlameCache[filename] == nil then
            M.update_git_blame(filename)
        end
        local blame = GitBlameCache[filename][row] or {}
        table.insert(global_marks, {char, row, filename, blame})
    end
    return global_marks
end

--- Get local vimmarks only
---
--- @Related restore_local_marks()
--- @return table[] # list of vimmark details [{char, row, details}, {...}]
function M.scan_vimmarks(target_bufnr)
    local vimmarks = {}
    local filename = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(target_bufnr), ":.")
    if GitBlameCache[filename] == nil then
        M.update_git_blame(filename)
    end
    for _, item in ipairs(vim.fn.getmarklist(target_bufnr)) do
        local char = item.mark:sub(2,2)
        local bufnr, row, _, _ = unpack(item.pos)
        local blame = GitBlameCache[filename][row] or {}
        if char:match('[a-z]') ~= nil then
            table.insert(vimmarks, {char, row, blame})
        end
    end
    return vimmarks
end

--- Get notes(extmarks) from given buffer
---
--- @Related restore_local_marks()
--- @return table[] # list of extmark details [{mark_id, row, lines}, {...}]
function M.scan_notes(bufnr)
    local notes = {}
    local items = vim.api.nvim_buf_get_extmarks(bufnr, NS_Notes, 0, -1, {details=true})
    local filename = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":.")
    if GitBlameCache[filename] == nil then
        M.update_git_blame(filename)
    end
    local blame = GitBlameCache[filename][row] or {}
    for _, ext in ipairs(items) do
        -- print('scanned an extmark', vim.inspect(ext))
        local mark_id, row, _, details = unpack(ext)  -- details: vim.api.keyset.set_extmark
        table.insert(notes, {mark_id, row+1, details.virt_lines, blame})
    end
    return notes
end

--- Scan multiple vimmarks on a given row
---
--- @return string[] #  Signs of Vimmarks
function M.get_mark_chars_by_row(target_bufnr, target_row)
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
function M.set_vimmark(bufnr, char, row)
    vim.api.nvim_buf_set_mark(bufnr, char, row, 0, {})
end

function M.delete_vimmark(bufnr, row)
    local markchars = get_mark_chars_by_row(bufnr, row)
    for _, char in ipairs(markchars) do
        vim.api.nvim_buf_del_mark(bufnr, char)
    end
end

function M.delete_note(target_bufnr, target_row)
    local notes = scan_notes(target_bufnr)
    for _, item in ipairs(notes) do
        local mark_id, row, _, _ = unpack(item)
        if row == target_row then
            vim.api.nvim_buf_del_extmark(target_bufnr, NS_Notes, mark_id)
        end
    end
end


--- Related: @scan_global_vimmarks()
function M.restore_global_marks()
    local json_path = M.make_json_path('vimmarks_global')
    local global_marks = M.load_json(json_path) or {}  --- @type table[] # [{char=a, row=1, filename=abc}, {...}]
    for _, item in ipairs(global_marks) do
        local char, row, filename, _ = unpack(item)
        local bufnr = vim.fn.bufadd(filename)  -- Will not add/load existing buffer but return existing id
        vim.fn.bufload(bufnr)
        vim.api.nvim_buf_set_mark(bufnr, char, row, 0, {})
    end
end

--- @Related scan_vimmarks()
--- @Related scan_notes()
function M.restore_local_marks(bufnr)
    local filename = vim.api.nvim_buf_get_name(bufnr)
    local json_path = M.make_json_path(filename)
    local data = M.load_json(json_path) or {vimmarks={}, notes={}}
    -- print('restoring from', json_path, vim.inspect(data))
    -- Restore local vimmarks
    for _, item in ipairs(data['vimmarks'] or {}) do
        local char, row, _ = unpack(item)
        vim.api.nvim_buf_set_mark(bufnr, char, row, 0, {})
    end
    -- Restore local notes
    for _, ext in ipairs(data['notes'] or {}) do
        local mark_id, row, virt_lines, _ = unpack(ext)
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


--- Scan latest vimmarks and update left sign bar
--- Don't use vim native signs like `sign_define/sign_place` because neovim will create extmarks anyways
function M.update_sign_column(bufnr)
    if bufnr == 0 then bufnr = vim.api.nvim_get_current_buf() end  -- Get real bufnr (0 means current)
    local vimmarks = M.scan_vimmarks(bufnr)  --  mark={char, filename, row}
    vim.api.nvim_buf_clear_namespace(bufnr, NS_Signs, 0, -1)  -- Delete all signs then add each
    -- Local signs
    for _, item in ipairs(vimmarks) do
        local char, row, _ = unpack(item)
        vim.api.nvim_buf_set_extmark(bufnr, NS_Signs, row-1, 0, {
            id=math.random(1000, 9999),
            end_row=row-1,  -- extmark is 0-indexed
            end_col=0,
            sign_text=char,
            sign_hl_group='WarningMsg',
        })
    end
    -- Global signs
    local global_marks = M.scan_global_vimmarks()  --  mark={char, filename, row}
    -- print('updating global_marks', #global_marks, 'signs for', bufnr)
    local buf_filename = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":.")
    for _, item in ipairs(global_marks) do
        local char, row, filename, _ = unpack(item)
        if filename == buf_filename then
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


--- Blame whole file, and extract meta info of each line
---
--- @return string[]|nil # Array of blamed lines [{commit_id, filename, author, time, row, line_content, surrounding_content}]
function M.update_git_blame(filename)
    local cmd = { 'git', 'blame', '--date=unix', '-c', filename }
    print('Executing cmd', vim.inspect(cmd))
    local obj = vim.system(cmd, {text = true}):wait()
    if obj.code ~= 0 then
        print('Git blame failed: ' .. obj.stderr)
        return nil
    end
    local blamed_lines = {}
    for line in obj.stdout:gmatch("[^\r\n]+") do
        -- print('Parsing blame line', line)
        --- e.g., a3672a14        (My Name     1768430769      14)
        --- e.g., 00000000        (Not Committed Yet      1768707934      15)local SetupStatusPerBuf = ...
        local commit_id, author, timestamp, row, content = line:match("^(%x+)%s+%(%s*(.-)\t+(%d+)\t+(%d+)%)(.*)$")
        local blame = {commit_id, author, timestamp, row, content }
        -- print('parsed info', vim.inspect(blame))
        table.insert(blamed_lines, blame)
    end
    GitBlameCache[filename] = blamed_lines
    return blamed_lines
end


function M.setup(opt)
    -- ...
end


return M
