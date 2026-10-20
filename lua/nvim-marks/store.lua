--- One JSONL file per repo holds the marks and notes of all its files, shared by every worktree and branch.
---
--- Location: `<dir>/<repo>/marks.jsonl`, <dir> from setup({dir=...}) or g:nvim_marks_dir, default `stdpath('data')/nvim-marks`.
--- <repo> is the folder name of the repo's main checkout, the same for all its worktrees.
--- Files are keyed by their path from the repo root, so `src/a.lua` is the same file in every worktree.
---
--- One line per mark/note, in the order they were added, so git diffs stay one line per change.
--- new ones are appended, an edited or moved one rewrites its own line, a deleted one removes its line.
---   {"id":"3f9a1c0e","file":"src/a.lua","kind":"note","text":"why?\nsecond line","row":24,"line":"def run(","above":["e3b0c442","e3b0c442"],"below":["2a497258","60b6a494"]}
---   {"id":"b71d22aa","file":"src/a.lua","kind":"mark","char":"a","row":8,"line":"local x = 1","above":[...],"below":[...]}
--- `text` is the note, its lines joined with `\n`. `row`, `line`, `above`, `below` are the anchor (see anchor.lua). A record whose line can't be found in the current
--- version of the file (e.g. on another branch) is left as it is until it's found again or deleted.

local M = {}

M.DEFAULT_DIR = vim.fn.stdpath('data') .. '/nvim-marks'
M.dir_option = nil  --- @type string|nil # set by setup()
M.FILE_NAME = 'marks.jsonl'
local OLD_FILE_NAME = 'marks-history.json'  -- previous format, read once when there's no marks.jsonl yet
local KEY_ORDER = {'id', 'file', 'kind', 'char', 'text', 'row', 'line', 'above', 'below'}

local RepoCache = {}  --- @type table<string, table> # {dir={top, repo}}

--- @param path string # absolute file path
--- @return table # {top=repo root or nil, repo=string}
function M.repo_info(path)
    local dir = vim.fs.dirname(path)
    if RepoCache[dir] then return RepoCache[dir] end
    local cmd = {'git', '-C', dir, 'rev-parse', '--path-format=absolute', '--show-toplevel', '--git-common-dir'}
    local obj = vim.system(cmd, {text=true}):wait()
    local info = {top=nil, repo='_no_repo'}
    if obj.code == 0 then
        local top, common_dir = unpack(vim.split(vim.trim(obj.stdout), '\n'))
        info = {top=top, repo=M.repo_name(top, common_dir)}
    end
    RepoCache[dir] = info
    return info
end

--- Name of a repo, the same in every worktree: the folder name of its main checkout
---
--- @param top string # this checkout's root
--- @param common_dir string # git dir shared by all worktrees
function M.repo_name(top, common_dir)
    if vim.fs.basename(common_dir) == '.git' then
        return vim.fs.basename(vim.fs.dirname(common_dir))  -- `<main>/.git`
    end
    if vim.fs.basename(common_dir):match('^%.') then
        return vim.fs.basename(top)  -- separate git dir like `~/.dot.git` for `~/dot`: name it after the checkout
    end
    return (vim.fs.basename(common_dir):gsub('%.git$', ''))  -- bare repo `myapp.git`
end

--- Work files kept under the marks folder (`<dir>/<repo>/...`) belong with that repo's marks
---
--- @return table|nil # {top=<dir>/<repo>, repo=<repo>} when `path` is inside one
function M.work_files_repo(path)
    local dir = vim.fn.resolve(vim.fn.expand(M.dir_option or vim.g.nvim_marks_dir or M.DEFAULT_DIR)):gsub('/$', '')
    if not vim.startswith(path, dir .. '/') then return nil end
    local repo = path:sub(#dir + 2):match('^([^/]+)/')
    if repo == nil or repo:match('^%.') then return nil end
    return {top=dir .. '/' .. repo, repo=repo}
end

--- @return string # path from the repo root, or the absolute path outside a repo
function M.file_key(path, info)
    if info.top and vim.startswith(path, info.top .. '/') then
        return path:sub(#info.top + 2)
    end
    return path
end

--- @return string # store file for the repo
function M.store_path(info)
    local dir = M.dir_option or vim.g.nvim_marks_dir or M.DEFAULT_DIR
    return vim.fn.expand(dir) .. '/' .. info.repo .. '/' .. M.FILE_NAME
end

--- @return string # a new record id
function M.new_id()
    return vim.fn.sha256(tostring(vim.uv.hrtime()) .. math.random()):sub(1, 8)
end

--- @return string # one JSON line, keys in a fixed order so a record's line only changes when its values do
--- A note's lines are saved as one string joined with newlines; in memory `text` is a list of lines
function M.encode_record(record)
    local saved = vim.tbl_extend('force', record, {text=record.text and table.concat(record.text, '\n')})
    local parts = {}
    for _, key in ipairs(KEY_ORDER) do
        if saved[key] ~= nil then table.insert(parts, vim.json.encode(key) .. ':' .. vim.json.encode(saved[key])) end
    end
    return '{' .. table.concat(parts, ',') .. '}'
end

--- @return table|nil # record from one JSONL line, `text` split back into lines
function M.decode_record(json_line)
    local ok, record = pcall(vim.json.decode, json_line)
    if not ok or type(record) ~= 'table' or not record.id or not record.file then return nil end
    if type(record.text) == 'string' then record.text = vim.split(record.text, '\n', {plain=true}) end
    if record.line_b64 then  -- written briefly by an earlier version
        local decoded_ok, line = pcall(vim.base64.decode, record.line_b64)
        record.line = decoded_ok and line or ''
        record.line_b64 = nil
    end
    return record
end

--- Records from a marks-history.json (v2 or v3), the format before JSONL
local function convert_old_json(old_path)
    local f = io.open(old_path, 'r')
    if not f then return nil end
    local content = f:read('*all')
    f:close()
    local ok, data = pcall(vim.json.decode, content)
    if not ok or type(data) ~= 'table' or type(data.files) ~= 'table' then return nil end
    local anchor = require('nvim-marks.anchor')
    local keys = vim.tbl_keys(data.files)
    table.sort(keys)
    local records = {}
    for _, key in ipairs(keys) do
        for _, kind in ipairs({'marks', 'notes', 'orphans'}) do
            for _, item in ipairs(data.files[key][kind] or {}) do
                local a = anchor.upgrade(item.anchor)
                table.insert(records, {
                    id=M.new_id(), file=key, kind=item.char and 'mark' or 'note', char=item.char, text=item.text,
                    row=a.row, line=a.line, above=a.above, below=a.below,
                })
            end
        end
    end
    return records
end

--- @return table[] # records in file order
function M.load(store_path)
    local f = io.open(store_path, 'r')
    if not f then
        return convert_old_json(vim.fs.dirname(store_path) .. '/' .. OLD_FILE_NAME) or {}
    end
    local records = {}
    for line in f:lines() do
        if vim.trim(line) ~= '' then
            local record = M.decode_record(line)
            if record then
                table.insert(records, record)
            else
                vim.notify('nvim-marks: skipped a bad line in ' .. store_path .. ': ' .. line, vim.log.levels.WARN)
            end
        end
    end
    f:close()
    return records
end

--- @return integer|nil # last change time of the store file in ns, nil if it doesn't exist
function M.mtime(store_path)
    local stat = vim.uv.fs_stat(store_path)
    return stat and (stat.mtime.sec * 1e9 + stat.mtime.nsec) or nil
end

--- Write to a temp file then rename, so a crash or another nvim never leaves half a file
function M.save(store_path, records)
    vim.fn.mkdir(vim.fs.dirname(store_path), 'p')
    local tmp_path = store_path .. '.tmp' .. vim.fn.getpid()
    local f = io.open(tmp_path, 'w')
    if not f then
        vim.notify('nvim-marks: cannot write ' .. store_path, vim.log.levels.WARN)
        return
    end
    for _, record in ipairs(records) do f:write(M.encode_record(record), '\n') end
    f:close()
    os.rename(tmp_path, store_path)
end

--- Replace one file's records with `current`, keeping every record's place:
--- same id → rewritten in place, new → appended at the end. Other files' records are untouched.
--- A saved record missing from `current` is removed only if its id is in `known` (this nvim loaded it, then it
--- was deleted); one added meanwhile by another nvim or a `git pull` is kept.
---
--- A note whose text this nvim hasn't changed since loading it keeps the text on disk, so an edit made elsewhere
--- (another nvim, a script) isn't reverted by a save here.
---
--- @param known table<string, boolean> # ids this nvim loaded or created for the file
--- @param loaded_texts table<string, string[]>|nil # {id=text} of notes as this nvim last loaded or saved them
--- @return table[], boolean # merged records, whether anything changed
function M.merge_file(records, file, current, known, loaded_texts)
    local by_id = {}
    for _, record in ipairs(current) do by_id[record.id] = record end
    local merged, changed, seen = {}, false, {}
    for _, record in ipairs(records) do
        if record.file ~= file then
            table.insert(merged, record)
        elseif by_id[record.id] then
            local new = by_id[record.id]
            local loaded = loaded_texts and loaded_texts[record.id]
            if new.kind == 'note' and loaded and vim.deep_equal(new.text, loaded) then
                new = vim.tbl_extend('force', new, {text=record.text})  -- not edited here: keep theirs
            end
            if M.encode_record(new) ~= M.encode_record(record) then changed = true end
            table.insert(merged, new)
            seen[record.id] = true
        elseif known[record.id] then
            changed = true  -- deleted here
        else
            table.insert(merged, record)  -- added elsewhere, not loaded here yet
        end
    end
    for _, record in ipairs(current) do
        if not seen[record.id] then
            table.insert(merged, record)
            changed = true
        end
    end
    return merged, changed
end

--- Change a record's text, or delete it (text=nil)
function M.edit_record(store_path, id, text)
    local records = M.load(store_path)
    for i, record in ipairs(records) do
        if record.id == id then
            if text then record.text = text else table.remove(records, i) end
            M.save(store_path, records)
            return
        end
    end
end

--- Read marks saved by the old version (`<repo>/.git/persistent_marks/<project>/<a__b.lua>.json`), rows only
---
--- @return table|nil # {marks={{char, row}}, notes={{text, row}}}
function M.load_legacy(info, key)
    if not info.top then return nil end
    local flat_name = key:gsub('/', '__')
    local legacy_path = string.format('%s/.git/persistent_marks/%s/%s.json', info.top, vim.fs.basename(info.top), flat_name)
    local f = io.open(legacy_path, 'r')
    if not f then return nil end
    local ok, data = pcall(vim.json.decode, f:read('*all'))
    f:close()
    if not ok or type(data) ~= 'table' or (data.vimmarks == nil and data.notes == nil) then return nil end
    local legacy = {marks={}, notes={}}
    for _, item in ipairs(data.vimmarks or {}) do
        table.insert(legacy.marks, {char=item[1], row=item[2]})
    end
    for _, item in ipairs(data.notes or {}) do
        local text = {}
        for _, chunks in ipairs(item[4] or {}) do table.insert(text, chunks[1] and chunks[1][1] or '') end
        table.insert(legacy.notes, {text=text, row=item[2]})
    end
    return legacy
end


--- Tests: `nvim -l tests/run.lua`
local function fixture_path(name)
    return vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2)) .. '/../../tests/fixtures/' .. name
end

local function eq(actual, expected, msg)
    assert(vim.deep_equal(actual, expected), string.format('%s: expected %s, got %s', msg, vim.inspect(expected), vim.inspect(actual)))
end

function M.test_store_path()
    local info = {top='/w/myapp-fix', repo='myapp'}
    M.dir_option = '/marks'
    eq(M.store_path(info), '/marks/myapp/marks.jsonl', 'dir')
    M.dir_option = nil
end

function M.test_repo_name()
    eq(M.repo_name('/w/myapp-fix', '/w/myapp/.git'), 'myapp', 'worktree of a normal repo')
    eq(M.repo_name('/home/me/dot', '/home/me/.dot.git'), 'dot', 'separate hidden git dir')
    eq(M.repo_name('/w/myapp-wt', '/srv/myapp.git'), 'myapp', 'bare repo')
end

function M.test_work_files_repo()
    M.dir_option = '/notes'
    eq(M.work_files_repo('/notes/myapp/myapp-fix-login/plan.md'), {top='/notes/myapp', repo='myapp'}, 'work file')
    eq(M.work_files_repo('/notes/nvim-marks-README.md'), nil, 'file directly in the folder')
    eq(M.work_files_repo('/w/myapp/a.lua'), nil, 'outside the folder')
    M.dir_option = nil
end

function M.test_file_key()
    local info = {top='/w/myapp'}
    eq(M.file_key('/w/myapp/src/a.lua', info), 'src/a.lua', 'inside repo')
    eq(M.file_key('/other/b.lua', info), '/other/b.lua', 'outside repo')
end

function M.test_load_and_encode()
    local records = M.load(fixture_path('marks.jsonl'))
    eq(#records, 3, 'one record per line')
    eq(records[1].text, {'why fetch it again?'}, 'note text')
    eq(records[3].text, {'two', 'lines'}, 'one string in the file, lines in memory')
    eq(records[3].line, '    return "job"', 'code line as it was')
    local lines = vim.fn.readfile(fixture_path('marks.jsonl'))
    for i, record in ipairs(records) do eq(M.encode_record(record), lines[i], 'line ' .. i .. ' written back as it was') end
end

function M.test_merge_file_keeps_places()
    local records = M.load(fixture_path('marks.jsonl'))
    local moved = vim.deepcopy(records[1])
    moved.row = 30
    local added = {id='99999999', file='jobs/common.py', kind='mark', char='z', row=1, line='import os', above={}, below={}}
    -- jobs/common.py now has: note 1 moved, note 3 deleted, a new mark
    local known = {[records[1].id]=true, [records[3].id]=true}
    local merged, changed = M.merge_file(records, 'jobs/common.py', {moved, added}, known)
    eq(changed, true, 'changed')
    eq(vim.tbl_map(function(r) return r.id end, merged), {records[1].id, records[2].id, '99999999'}, 'moved in place, deleted removed, new appended')
    eq(merged[1].row, 30, 'moved row')
    local _, unchanged = M.merge_file(records, 'jobs/common.py', {records[1], records[3]}, known)
    eq(unchanged, false, 'nothing changed')
    -- note 3 was added by another nvim after this one loaded the file: not deleted
    local kept = M.merge_file(records, 'jobs/common.py', {records[1]}, {[records[1].id]=true})
    eq(#kept, 3, 'record added elsewhere is kept')
end

--- A note edited elsewhere while this nvim had it open is kept, unless this nvim edited it too
function M.test_merge_file_keeps_text_edited_elsewhere()
    local records = M.load(fixture_path('marks.jsonl'))
    local id = records[1].id
    local in_nvim = vim.deepcopy(records[1])
    local on_disk = vim.deepcopy(records)
    on_disk[1].text = vim.list_extend(vim.deepcopy(records[1].text), {'--', 'Bot reply:', 'answer'})
    local loaded = {[id]=records[1].text}
    local merged, changed = M.merge_file(on_disk, 'jobs/common.py', {in_nvim, records[3]}, {[id]=true}, loaded)
    eq(merged[1].text, on_disk[1].text, 'reply written elsewhere kept')
    eq(changed, false, 'nothing to write')
    in_nvim.text = {'edited in nvim'}
    local edited = M.merge_file(on_disk, 'jobs/common.py', {in_nvim, records[3]}, {[id]=true}, loaded)
    eq(edited[1].text, {'edited in nvim'}, 'edit made here wins')
end

function M.test_convert_old_json()
    local records = convert_old_json(fixture_path('marks-history-v3.json'))
    eq(#records, 2, 'every note and mark converted')
    eq({records[1].kind, records[1].text, records[1].row}, {'note', {'one', 'two'}, 2}, 'note')
    eq({records[2].file, records[2].kind, records[2].char}, {'a.lua', 'mark', 'b'}, 'orphan mark')
    eq(#records[2].above, 1, 'v2 context lines turned into hashes')
end

return M
