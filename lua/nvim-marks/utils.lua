local M = {}

M.NS_Signs = vim.api.nvim_create_namespace('nvim-marks.signs')
M.NS_Notes = vim.api.nvim_create_namespace('nvim-marks.notes')
M.BlameCache = {}  --- @type table{string, table}  # {filename={blame_tuple}}
M.RenameHistory = {}  --- @type table{string, table}  # {filename={name1, name2}}

local ValidMarkChars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ'

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
    local persistent_dir = vim.g.nvim_marks_persistent_dir or (proj_root .. '/.git/persistent_marks')
    local json_path = persistent_dir .. '/' .. proj_name .. '/' .. flatten_name .. '.json'
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
---
--- @return table[] # list of vimmark details [{char, row, filename, details}, {...}]
function M.scan_global_vimmarks()
    local global_marks = {}
    for _, item in ipairs(vim.fn.getmarklist()) do
        local char = item.mark:sub(2,2)
        local bufnr, row, _, _ = unpack(item.pos)
        local filename = vim.fn.fnamemodify(item.file, ":.")
        local renames = RenameHistory[filename]
        if renames == nil then RenameHistory[filename] = M.git_rename_history(filename) end
        for _, fn in ipair(renames) do
            if M.BlameCache[fn] == nil then M.BlameCache[fn] = M.git_blame(fn) end
            if M.BlameCache[fn] ~= nil and M.BlameCache[fn][row] ~! nil then
                local blame = M.BlameCache[fn][row]
                table.insert(global_marks, {char, row, fn, blame})
            end
        end

    end
    return global_marks
end

--- Get local vimmarks only
---
--- @return table[] # list of vimmark details [{char, row, details}, {...}]
function M.scan_vimmarks(target_bufnr)
    local vimmarks = {}
    local filename = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(target_bufnr), ":.")
    for _, item in ipairs(vim.fn.getmarklist(target_bufnr)) do
        local char = item.mark:sub(2,2)
        local bufnr, row, _, _ = unpack(item.pos)
        local blame = M.BlameCache[filename] and M.BlameCache[filename][row] or {}
        if char:match('[a-z]') ~= nil then
            table.insert(vimmarks, {char, row, blame})
        end
    end
    return vimmarks
end

--- Get notes(extmarks) from given buffer
---
--- @return table[] # list of extmark details [{mark_id, row, lines}, {...}]
function M.scan_notes(bufnr)
    local notes = {}
    local items = vim.api.nvim_buf_get_extmarks(bufnr, M.NS_Notes, 0, -1, {details=true})
    local filename = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":.")
    local blame = M.BlameCache[filename] and M.BlameCache[filename][row] or {}
    for _, ext in ipairs(items) do
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
    local markchars = M.get_mark_chars_by_row(bufnr, row)
    for _, char in ipairs(markchars) do
        vim.api.nvim_buf_del_mark(bufnr, char)
    end
end

function M.delete_note(target_bufnr, target_row)
    local notes = M.scan_notes(target_bufnr)
    for _, item in ipairs(notes) do
        local mark_id, row, _, _ = unpack(item)
        if row == target_row then
            vim.api.nvim_buf_del_extmark(target_bufnr, M.NS_Notes, mark_id)
        end
    end
end


function M.restore_global_marks()
    local json_path = M.make_json_path('vimmarks_global')
    local global_marks = M.load_json(json_path) or {}  --- @type table[] # [{char=a, row=1, filename=abc}, {...}]
    for _, item in ipairs(global_marks) do
        local char, row, filename, blame = unpack(item)
        -- todo: smart matching
        -- issue: 1) target filename change; 2) in case of change, how to read whole file to find match
        if vim.g.nvim_marks_restore_global == 1 then
            local bufnr = vim.fn.bufadd(filename)  -- Will not reload existing buffer but return existing id
            vim.fn.bufload(bufnr)
            vim.api.nvim_buf_set_mark(bufnr, char, row, 0, {})
        end
    end
end

function M.restore_marks(bufnr)
    -- todo: smart matching
    -- issue: 1) target filename change; 2) in case of change, how to read whole file to find match
    local filename = vim.api.nvim_buf_get_name(bufnr)
    local json_path = M.make_json_path(filename)
    local data = M.load_json(json_path) or {vimmarks={}, notes={}}
    -- Restore local vimmarks
    for _, item in ipairs(data['vimmarks'] or {}) do
        local char, row, _ = unpack(item)
        vim.api.nvim_buf_set_mark(bufnr, char, row, 0, {})
    end
    -- Restore local notes
    for _, ext in ipairs(data['notes'] or {}) do
        local mark_id, row, virt_lines, _ = unpack(ext)
        vim.api.nvim_buf_set_extmark(bufnr, M.NS_Notes, row, 0, {
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
function M.refresh_sign_bar(bufnr)
    if bufnr == 0 then bufnr = vim.api.nvim_get_current_buf() end  -- Get real bufnr (0 means current)
    local vimmarks = M.scan_vimmarks(bufnr)  --  mark={char, filename, row}
    vim.api.nvim_buf_clear_namespace(bufnr, M.NS_Signs, 0, -1)  -- Delete all signs then add each
    -- Local signs
    for _, item in ipairs(vimmarks) do
        local char, row, _ = unpack(item)
        vim.api.nvim_buf_set_extmark(bufnr, M.NS_Signs, row-1, 0, {
            id=math.random(1000, 9999),
            end_row=row-1,  -- extmark is 0-indexed
            end_col=0,
            sign_text=char,
            sign_hl_group='WarningMsg',
        })
    end
    -- Global signs
    local global_marks = M.scan_global_vimmarks()  --  mark={char, filename, row}
    local buf_filename = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":.")
    for _, item in ipairs(global_marks) do
        local char, row, filename, _ = unpack(item)
        if filename == buf_filename then
            vim.api.nvim_buf_set_extmark(bufnr, M.NS_Signs, row-1, 0, {
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


--- Get all past file names of a given file (by git)
---
--- @return string[] # [filename1, filename2...]
function M.git_rename_history(filename)
    local cmd = string.format('git log --follow --name-only --format="" %s |uniq', filename)
    local obj = vim.system({'sh', '-c', cmd}, {text = true}):wait()
    if obj.code ~= 0 then
        --- Files not tracked by git won't return data
        -- print('Command failed: ' .. obj.stderr)
        return {}
    end
    local names = {}
    local lines = vim.split(obj.stdout, '[\r\n]+')
    for _, s in ipairs(lines) do
        if s ~= '' then table.insert(names, vim.trim(s)) end
    end
    return names
end


--- Blame whole file, and extract meta info of each line
---
--- @performance 2ms # means no need async for this
--- @return string[] # Array of blamed hash items [{details}, {details}]
function M.git_blame(filename)
    local cmd = { 'git', 'blame', '--date=unix', '-c', filename }
    local obj = vim.system(cmd, {text = true}):wait()
    if obj.code ~= 0 then
        --- Files not tracked by git won't return data
        -- print('Command failed: ' .. obj.stderr)
        return {}
    end
    local lines = vim.split(obj.stdout, '[\r\n]+')
    local blames = {}
    for i=1, #lines do
        --- e.g., a3672a14        (My Name     1768430769      14)if anything then...
        --- e.g., 00000000        (Not Committed Yet      1768707934      15)local SetupStatusPerBuf = ...
        line = vim.trim(lines[i])
        local commit_id, author, timestamp, row, content = line:match("^(%x+)%s+%(%s*(.-)\t+(%d+)\t+(%d+)%)(.*)$")
        if row == nil or content == nil then goto continue end
        -- Find surroundings:
        -- if 10 rows total:
        -- row=1, prev=1, next=4
        -- row=2, prev=1, next=5
        -- row=3, prev=1, next=6
        -- row=4, prev=1, next=7
        -- row=5, prev=2, next=8
        -- row=6, prev=3, next=9
        -- row=7, prev=4, next=10
        -- row=8, prev=5, next=10
        -- row=9, prev=6, next=10
        -- row=10, prev=7, next=10
        local prev_pos = math.max(1, i-3)
        local next_pos = math.min(#line, i+3)
        local prev = table.concat(vim.list_slice(lines, prev_pos, i), '\n')
        local next = table.concat(vim.list_slice(lines, i, next_pos), '\n')
        local percentile = math.floor((row / #lines) * 100) -- Rough positions (1-100%)
        local info = {
            commit_id = commit_id,
            author = author,
            timestamp = timestamp,
            -- row = row,
            percentile = percentile,
            content = content,
            prev = prev,
            next = next,
        }
        table.insert(blames, info)
        ::continue::
    end
    return blames
end

--- Levenshtein Distance: calculate similarity between two strings
--- It will check how many characters to change in order to get from str1->str2
--- e.g., 'haha' & 'haha' -> 100; 'haha'&'hiha' -> 75; 'haha'&'lol'->0
---
--- @reference https://en.wikipedia.org/wiki/Levenshtein_distance
--- @return integer # 0-100%. 100 - identical; 0 - completely different
function M.levenshtein_distance(str1, str2)
    if str1 == str2 then return 100 end
    if #str1 == 0 or #str2 == 0 then return 0 end
    local v0 = {}
    for i = 0, #str2 do v0[i] = i end
    for i = 1, #str1 do
        local v1 = { [0] = i }
        for j = 1, #str2 do
            local cost = (str1:sub(i, i) == str2:sub(j, j)) and 0 or 1
            v1[j] = math.min(v1[j - 1] + 1, v0[j] + 1, v0[j - 1] + cost)
        end
        v0 = v1
    end
    local distance = v0[#str2]
    -- Normalize to 100%:
    local max_len = math.max(#str1, #str2)
    if max_len == 0 then return 100 end
    local similarity = (1 - (distance / max_len)) * 100
    return similarity
end


function M.setup(opt)
    -- ...
end


return M
