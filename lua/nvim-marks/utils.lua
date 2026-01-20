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
    content = vim.trim(content)
    if content ~= '' then
        return vim.json.decode(content) or {}
    end
    return {}
end


function M.update_git_blame_cache()
    -- Scan files in global marks
    local marked_files = {}  --- @type table # {filename=true}
    local json_path = M.make_json_path('vimmarks_global')
    for _, item in ipairs(M.load_json(json_path) or {}) do
        local _, _, filename, _ = unpack(item)
        if filename ~= nil then marked_files[filename] = true end
    end
    -- Scan files in each local mark file
    for path, _ in vim.fs.dir(json_path) do
        local data = M.load_json(json_path) or {vimmarks={}, notes={}}
        for _, item in ipairs(data['vimmarks'] or {}) do
            local _, _, filename, _ = unpack(item)
            if filename ~= nil then marked_files[filename] = true end
        end
        for _, item in ipairs(data['notes'] or {}) do
            local _, _, filename, _, _ = unpack(item)
            if filename ~= nil then marked_files[filename] = true end
        end
    end
    for filename, _ in pairs(marked_files) do
        -- Git blames
        M.BlameCache[filename] = M.git_blame(filename)
        -- Git rename history
        M.RenameHistory[filename] = M.git_rename_history(filename)
    end
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
        local blame = M.BlameCache[filename] and M.BlameCache[filename][row] or {}
        table.insert(global_marks, {char, row, filename, blame})
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
            table.insert(vimmarks, {char, row, filename, blame})
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
    for _, ext in ipairs(items) do
        local mark_id, row, _, details = unpack(ext)  -- details: vim.api.keyset.set_extmark
        local blame = M.BlameCache[filename] and M.BlameCache[filename][row] or {}
        table.insert(notes, {mark_id, row+1, filename, details.virt_lines, blame})
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
        local mark_id, row, _, _, _, _ = unpack(item)
        if row == target_row then
            vim.api.nvim_buf_del_extmark(target_bufnr, M.NS_Notes, mark_id)
        end
    end
end

--- Save global vimmarks and local vimmarks+notes
function M.save_all(bufnr)
    M.update_git_blame_cache()  -- Update latest blames before saving (could be changed by external editors)
    local filename = vim.api.nvim_buf_get_name(bufnr)
    if bufnr == nil then return end
    -- Save local vimmarks+notes
    local vimmarks = M.scan_vimmarks(bufnr)
    local notes = M.scan_notes(bufnr)
    json_path = M.make_json_path(filename)
    -- print('saving vimmarks/notes to', #vimmarks, #notes, json_path)
    if #vimmarks > 0 or #notes > 0 then
        local data = {vimmarks=vimmarks, notes=notes}
        M.save_json(data, json_path)
    else
        os.remove(json_path) -- Delete empty files if no marks at all
    end
    -- Save global vimmarks
    local global_marks = M.scan_global_vimmarks()
    local json_path = M.make_json_path('vimmarks_global')
    if #global_marks > 0 then
        M.save_json(global_marks, json_path)
    else
        os.remove(json_path)
    end
end

function M.restore_global_marks()
    local json_path = M.make_json_path('vimmarks_global')
    local global_marks = M.load_json(json_path) or {}  --- @type table[] # [{char=a, row=1, filename=abc}, {...}]
    for _, item in ipairs(global_marks) do
        local char, row, filename, blame = unpack(item)
        if vim.g.nvim_marks_restore_global == 1 then
            local bufnr = vim.fn.bufadd(filename)  -- Will not reload existing buffer but return existing id
            vim.fn.bufload(bufnr)
            new_row = M.smart_match(bufnr, row, filename, blame)
            vim.api.nvim_buf_set_mark(bufnr, char, new_row, 0, {})
        end
    end
end

function M.restore_marks(bufnr)
    local filename = vim.api.nvim_buf_get_name(bufnr)
    local json_path = M.make_json_path(filename)
    local data = M.load_json(json_path) or {vimmarks={}, notes={}}
    -- Restore local vimmarks
    for _, item in ipairs(data['vimmarks'] or {}) do
        local char, row, _, blame = unpack(item)
        local new_row = M.smart_match(bufnr, row, filename, blame)
        -- print('Smart matched', old_row, 'vs', row, 'for', old_filename)
        if new_row > 0 then
            vim.api.nvim_buf_set_mark(bufnr, char, new_row, 0, {})
        end
    end
    -- Restore local notes
    for _, ext in ipairs(data['notes'] or {}) do
        local mark_id, row, _, virt_lines, _ = unpack(ext)
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


--- Smart matching
---
--- @return integer # matched latest row number of given info (-1 > no any confident matching found)
function M.smart_match(bufnr, old_row, old_filename, old_blame)
    local search_files = M.RenameHistory[old_filename] or {}
    -- Ensure current filename is in the list to search if it's the same file
    local current_filename = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":.")
    local found_current = false
    for _, f in ipairs(search_files) do
        if f == current_filename then found_current = true; break end
    end
    if not found_current then table.insert(search_files, 1, current_filename) end

    for _, filename in ipairs(search_files) do
        local latest_blame = M.BlameCache[filename] and M.BlameCache[filename][old_row] or {}
        local latest_content = latest_blame.content or ''
        local old_content = old_blame.content or ''
        -- Start to calculate matching score at original row
        local similarity = M.levenshtein_distance(old_content, latest_content)
        -- print('matching', old_content, latest_content, old_row, similarity)
        -- print(vim.inspect(old_blame))
        if similarity >= 0.9 then
            return old_row
        end
        -- Find a best match by iterating comparing every line
        local best_match = -1
        local best_similarity = -1
        local total_lines = vim.api.nvim_buf_line_count(bufnr)
        local blames = M.BlameCache[filename] or {}
        for new_row=1, total_lines do
            local new_blame = blames[new_row] or {}
            local content_similarity = M.levenshtein_distance(old_content, new_blame.content or '')
            -- Basic row similarity (closeness to original row)
            local row_dist = math.abs(old_row - new_row)
            local row_similarity = (1 - (row_dist / total_lines))
            -- Percentile similarity
            local old_pct = old_blame.percentile or 0
            local new_pct = new_blame.percentile or 0
            local percentile_similarity = (1 - (math.abs(old_pct - new_pct) / 100))
            -- Context similarity
            local prev_similarity = M.levenshtein_distance(old_blame.prev or '', new_blame.prev or '')
            local next_similarity = M.levenshtein_distance(old_blame.next or '', new_blame.next or '')
            -- calculate overall similarity score
            local overall_similarity = (content_similarity * 0.5) + (row_similarity * 0.1) +
                                       (percentile_similarity * 0.1) + (prev_similarity * 0.15) + (next_similarity * 0.15)

            if overall_similarity > 0.85 and overall_similarity > best_similarity then
                best_similarity = overall_similarity
                best_match = new_row
            end
        end
        -- print('tried rematching got best match', best_similarity, best_match)
        if best_match ~= -1 then
            return best_match
        end
    end
    -- Last resort: if same row content is decent, use it even if not "great"
    local current_blame = M.BlameCache[current_filename] and M.BlameCache[current_filename][old_row] or {}
    if M.levenshtein_distance(old_blame.content or '', current_blame.content or '') > 0.5 then
        return old_row
    end
    return -1
end


--- Scan latest vimmarks and update left sign bar
--- Don't use vim native signs like `sign_define/sign_place` because neovim will create extmarks anyways
function M.refresh_sign_bar(bufnr)
    if bufnr == 0 then bufnr = vim.api.nvim_get_current_buf() end  -- Get real bufnr (0 means current)
    local vimmarks = M.scan_vimmarks(bufnr)  --  mark={char, filename, row}
    vim.api.nvim_buf_clear_namespace(bufnr, M.NS_Signs, 0, -1)  -- Delete all signs then add each
    -- Local signs
    for _, item in ipairs(vimmarks) do
        local char, row, _, _ = unpack(item)
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
        local line_str = vim.trim(lines[i])
        local commit_id, author, timestamp, row_str, content = line_str:match("^(%x+)%s+%(%s*(.-)\t+(%d+)\t+(%d+)%)(.*)$")
        if row_str == nil or content == nil then goto continue end
        local row = tonumber(row_str) or -1
        local prev_pos = math.max(1, i-3)
        local next_pos = math.min(#lines, i+3)
        local prev_lines = {}
        for j = prev_pos, i-1 do table.insert(prev_lines, lines[j]) end
        local next_lines = {}
        for j = i+1, next_pos do table.insert(next_lines, lines[j]) end
        local info = {
            commit_id = commit_id,
            author = author,
            timestamp = timestamp,
            percentile = math.floor((row / #lines) * 100),
            content = content,
            prev = table.concat(prev_lines, '\n'),
            next = table.concat(next_lines, '\n'),
        }
        blames[row] = info
        ::continue::
    end
    return blames
end

--- Levenshtein Distance: calculate similarity between two strings
--- It will check how many characters to change in order to get from str1->str2
--- e.g., 'haha' & 'haha' -> 1; 'haha'&'hiha' -> 0.75; 'haha'&'lol'->0
---
--- @reference https://en.wikipedia.org/wiki/Levenshtein_distance
--- @return number # 0-1. 1 - identical; 0 - completely different
function M.levenshtein_distance(str1, str2)
    if str1 == str2 then return 1 end
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
    -- Normalize to 0-1:
    local max_len = math.max(#str1, #str2)
    if max_len == 0 then return 1 end
    local similarity = (1 - (distance / max_len))
    return similarity
end


function M.setup(opt)
    -- ...
end


return M
