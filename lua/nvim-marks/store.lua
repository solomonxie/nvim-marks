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
--- `commit` is HEAD (12 characters) when the anchor was last written: when the anchor isn't found, the row is carried
--- through the diff from that commit's version of the file, and a renamed file is followed (see utils.lua).

local M = {}

M.DEFAULT_DIR = vim.fn.stdpath('data') .. '/nvim-marks'
M.dir_option = nil  --- @type string|nil # set by setup()
M.FILE_NAME = 'marks.jsonl'
M.LOG_FILE_NAME = 'marks-log.jsonl'  -- next to the store: every add/update/delete, appended, never rewritten
local OLD_FILE_NAME = 'marks-history.json'  -- previous format, read once when there's no marks.jsonl yet
local KEY_ORDER = {'id', 'file', 'kind', 'char', 'status', 'text', 'row', 'line', 'above', 'below', 'commit'}
M.COMMIT_LEN = 12  -- git lengthens its own short hashes as a repo grows, 7 can turn ambiguous

--- A note's status, in the order `@` cycles through them and the marks list shows them
M.STATUSES = {'open', 'todo', 'anchor', 'done'}
--- Shown in front of a note (marks list, code line, editor bar); stored only as `status`, never in the text
M.STATUS_SYMBOLS = {open='', todo='(⏺)', done='(ok)', anchor='(#)'}
--- Statuses from earlier versions, read as their current name
local OLD_STATUS = {answered='todo', archived='done', read='done'}
--- Text prefixes the status replaces: `(⏺) ` todo, `(ok) ` done, `(#) ` anchor (`(-)` was anchor's earlier symbol)
local PREFIX_STATUS = {['(⏺)']='todo', ['(ok)']='done', ['(#)']='anchor', ['(-)']='anchor', ['(x)']='done'}

--- Move a note's old text prefixes into `status`, removing them from the text (once, on read)
--- Also renames statuses from earlier versions (`answered` is now `todo`, `archived` and `read` are `done`).
---
--- @return table # the same record
function M.status_from_prefixes(record)
    if record.status and OLD_STATUS[record.status] then record.status = OLD_STATUS[record.status] end
    if record.kind ~= 'note' or record.status then return record end
    local text = record.text
    if type(text) ~= 'table' or #text == 0 then return record end
    local first, status = text[1], nil
    while true do
        local tag, rest = first:match('^(%b())%s*(.*)$')
        if not tag or not PREFIX_STATUS[tag] then break end
        -- done wins over todo (`(ok) (⏺) ...` means done)
        local s = PREFIX_STATUS[tag]
        if status == nil or s == 'done' then status = s end
        first = rest
    end
    if status then
        record.text = vim.list_extend({first}, vim.list_slice(text, 2))
        record.status = status
    end
    return record
end

local RepoCache = {}  --- @type table<string, table> # {dir={top, repo}}
local KnownRoots = {}  --- @type table<string, table<string, boolean>> # {store_path={root=true}}: checkouts seen this session
local WorktreeCache = {}  --- @type table<string, string[]> # {root={worktree root, ...}}

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
--- @return string # the marks folder, resolved
local function marks_dir()
    return (vim.fn.resolve(vim.fn.expand(M.dir_option or vim.g.nvim_marks_dir or M.DEFAULT_DIR)):gsub('/$', ''))
end

function M.work_files_repo(path)
    local dir = marks_dir()
    if not vim.startswith(path, dir .. '/') then return nil end
    local repo = path:sub(#dir + 2):match('^([^/]+)/')
    if repo == nil or repo:match('^%.') then return nil end
    return {top=dir .. '/' .. repo, repo=repo}
end

--- Remember a checkout of a repo, so its files can be found from a buffer in another checkout or a work file
function M.remember_root(store_path, root)
    if not root then return end
    KnownRoots[store_path] = KnownRoots[store_path] or {}
    KnownRoots[store_path][root] = true
end

--- @return string[] # roots of every worktree of the git repo at `root` (empty when it isn't one)
local function worktrees(root)
    if WorktreeCache[root] then return WorktreeCache[root] end
    local roots = {}
    local obj = vim.system({'git', '-C', root, 'worktree', 'list', '--porcelain'}, {text=true}):wait()
    if obj.code == 0 then
        for _, line in ipairs(vim.split(obj.stdout, '\n')) do
            local wt = line:match('^worktree (.+)')
            if wt then table.insert(roots, vim.fn.resolve(wt)) end
        end
    end
    WorktreeCache[root] = roots
    return roots
end

--- Folders a repo's saved `file` paths can be relative to, best first: this buffer's checkout, the checkout
--- nvim's cwd is in, other checkouts seen this session and every worktree of them, then the repo's work-files folder
--- (notes on work files are relative to that). Paths aren't tied to the cwd or to one checkout.
---
--- @return string[]
function M.candidate_roots(store_path, info)
    local roots, seen = {}, {}
    local function add(root)
        if root and not seen[root] then
            seen[root] = true
            table.insert(roots, root)
        end
    end
    add(info.top)
    local cwd_info = M.repo_info(vim.fn.getcwd() .. '/.')
    if cwd_info.top and M.store_path(cwd_info) == store_path then add(cwd_info.top) end
    local known = vim.tbl_keys(KnownRoots[store_path] or {})
    table.sort(known)
    for _, root in ipairs(known) do add(root) end
    for _, root in ipairs(vim.list_slice(roots)) do
        for _, wt in ipairs(worktrees(root)) do add(wt) end
    end
    if info.repo ~= '_no_repo' then add(marks_dir() .. '/' .. info.repo) end
    return roots
end

local HeadCache = {}  --- @type table<string, table> # {top={commit, at}}: HEAD, read again after HEAD_TTL_NS
local HEAD_TTL_NS = 2e9
local FileAtCommit = {}  --- @type table<string, string[]|false> # {'top|commit|file'=lines}, a commit never changes
local RenameCache = {}  --- @type table<string, table> # {'top|commit|head'={old path=new path}}

--- @param top string|nil # repo root
--- @return string|nil # HEAD, short; nil outside a git repo (e.g. work files), or before the first commit
function M.head_commit(top)
    if not top then return nil end
    local now = vim.uv.hrtime()
    local cached = HeadCache[top]
    if cached and now - cached.at < HEAD_TTL_NS then return cached.commit or nil end
    local obj = vim.system({'git', '-C', top, 'rev-parse', '--show-toplevel', 'HEAD'}, {text=true}):wait()
    local commit = false
    if obj.code == 0 then
        local toplevel, head = unpack(vim.split(vim.trim(obj.stdout), '\n'))
        -- A folder inside another repo (the work-files folder in a dotfiles repo): paths aren't from that repo's root
        if vim.fn.resolve(toplevel) == vim.fn.resolve(top) and head then commit = head:sub(1, M.COMMIT_LEN) end
    end
    HeadCache[top] = {commit=commit, at=now}
    return commit or nil
end

--- @return string[]|nil # the file's lines at `commit`, nil when the commit is gone (rebased away) or hadn't the file
function M.file_at_commit(top, commit, file)
    local key = top .. '|' .. commit .. '|' .. file
    if FileAtCommit[key] == nil then
        local obj = vim.system({'git', '-C', top, 'show', commit .. ':' .. file}, {text=true}):wait()
        FileAtCommit[key] = obj.code == 0 and vim.split(obj.stdout:gsub('\n$', ''), '\n', {plain=true}) or false
    end
    return FileAtCommit[key] or nil
end

local AncestorCache = {}  --- @type table<string, boolean> # {'top|commit|head'=is ancestor}

--- @return boolean # `commit` is in HEAD's history. A note saved on another branch isn't: its line may still be there,
---                   so it stays an orphan instead of being moved by a diff against an unrelated version
function M.is_ancestor(top, commit)
    local head = M.head_commit(top)
    if not head then return false end
    local key = top .. '|' .. commit .. '|' .. head
    if AncestorCache[key] == nil then
        local obj = vim.system({'git', '-C', top, 'merge-base', '--is-ancestor', commit, 'HEAD'}):wait()
        AncestorCache[key] = obj.code == 0
    end
    return AncestorCache[key]
end

--- @return table<string, string> # {old path=new path} for files renamed since `commit`, up to the working tree
function M.renames_since(top, commit)
    local key = top .. '|' .. commit .. '|' .. (M.head_commit(top) or '')
    if RenameCache[key] then return RenameCache[key] end
    local renames = {}
    local obj = vim.system({'git', '-C', top, 'diff', '-M', '--name-status', '--diff-filter=R', commit, '--'}, {text=true}):wait()
    if obj.code == 0 then
        for _, line in ipairs(vim.split(obj.stdout, '\n')) do
            local old, new = line:match('^R%d*\t([^\t]+)\t([^\t]+)$')
            if old then renames[old] = new end
        end
    end
    RenameCache[key] = renames
    return renames
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
local IdCounter = 0

--- Unique even across nvim instances: `math.random()` starts from the same seed in every nvim, so mix in the
--- process id, a counter and the clock instead
function M.new_id()
    IdCounter = IdCounter + 1
    return vim.fn.sha256(vim.fn.getpid() .. ':' .. IdCounter .. ':' .. vim.uv.hrtime()):sub(1, 8)
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
    M.status_from_prefixes(record)
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
--- @return string # the change log next to a store file
function M.log_path(store_path)
    return vim.fs.dirname(store_path) .. '/' .. M.LOG_FILE_NAME
end

--- Append one line per record that differs between `old` and `new` to the change log, with the whole record
--- (`before` for update and delete, `after` for add and update), so any version can be put back by hand.
---   {"ts":"2026-10-20T14:05:11.042+0000","op":"update","id":"3f9a1c0e","file":"src/a.lua","by":"nvim 12345",
---    "before":{...record...},"after":{...record...}}
--- Only content changes are logged: a record that only moved (row/anchor) is an `update` too, so nothing is lost.
---
--- @return integer # lines appended
function M.append_log(store_path, old, new, by)
    local old_by_id, new_by_id = {}, {}
    for _, r in ipairs(old) do old_by_id[r.id] = r end
    for _, r in ipairs(new) do new_by_id[r.id] = r end
    local now = vim.uv.clock_gettime('realtime')
    local ts = os.date('!%Y-%m-%dT%H:%M:%S', now.sec) .. string.format('.%03dZ', math.floor(now.nsec / 1e6))
    local lines = {}
    local function entry(op, before, after)
        local r = after or before
        local parts = {
            '"ts":' .. vim.json.encode(ts), '"op":' .. vim.json.encode(op), '"id":' .. vim.json.encode(r.id),
            '"file":' .. vim.json.encode(r.file), '"by":' .. vim.json.encode(by or ('nvim ' .. vim.fn.getpid())),
        }
        if before then table.insert(parts, '"before":' .. M.encode_record(before)) end
        if after then table.insert(parts, '"after":' .. M.encode_record(after)) end
        table.insert(lines, '{' .. table.concat(parts, ',') .. '}')
    end
    for _, r in ipairs(old) do
        local n = new_by_id[r.id]
        if not n then entry('delete', r, nil)
        elseif M.encode_record(n) ~= M.encode_record(r) then entry('update', r, n) end
    end
    for _, r in ipairs(new) do
        if not old_by_id[r.id] then entry('add', nil, r) end
    end
    if #lines == 0 then return 0 end
    -- Opened in append mode: concurrent writers each add whole lines, nothing already there is touched
    local f = io.open(M.log_path(store_path), 'a')
    if not f then
        vim.notify('nvim-marks: cannot write ' .. M.log_path(store_path), vim.log.levels.WARN)
        return 0
    end
    f:write(table.concat(lines, '\n') .. '\n')
    f:close()
    return #lines
end

function M.save(store_path, records)
    vim.fn.mkdir(vim.fs.dirname(store_path), 'p')
    -- Log what this write changes compared with what's on disk right now (other writers' changes were logged by them)
    local on_disk = vim.uv.fs_stat(store_path) and M.load(store_path) or {}
    M.append_log(store_path, on_disk, records)
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
--- A record in `current` that this nvim has seen on disk before (`on_disk`) but that's gone now was deleted
--- elsewhere (an agent, another nvim): it's dropped, not written back, unless its text was edited here.
---
--- @param known table<string, boolean> # ids this nvim loaded or created for the file
--- The same goes for a note's status: one this nvim didn't change since loading keeps the status on disk.
---
--- @param loaded_texts table<string, string[]>|nil # {id=text} of notes as this nvim last loaded or saved them
--- @param on_disk table<string, boolean>|nil # ids this nvim has loaded from or saved to the store
--- @param loaded_statuses table<string, string|false>|nil # {id=status} as last loaded or saved (false: none)
--- @return table[], boolean # merged records, whether anything changed
function M.merge_file(records, file, current, known, loaded_texts, on_disk, loaded_statuses)
    local by_id = {}
    for _, record in ipairs(current) do by_id[record.id] = record end
    local merged, changed, seen = {}, false, {}
    for _, record in ipairs(records) do
        if record.file ~= file and by_id[record.id] then
            table.insert(merged, by_id[record.id])  -- its file was renamed to this one: moved here, same place
            seen[record.id] = true
            changed = true
        elseif record.file ~= file then
            table.insert(merged, record)
        elseif record.kind == 'note' and vim.trim(table.concat(record.text or {}, '\n')) == '' then
            changed = true  -- an empty note counts as deleted: drop it from the file
        elseif by_id[record.id] then
            local new = by_id[record.id]
            local loaded = loaded_texts and loaded_texts[record.id]
            if new.kind == 'note' and loaded and vim.deep_equal(new.text, loaded) then
                new = vim.tbl_extend('force', new, {text=record.text})  -- not edited here: keep theirs
            end
            if record.commit and new.row == record.row and new.line == record.line
                and vim.deep_equal(new.above, record.above) and vim.deep_equal(new.below, record.below) then
                new = vim.tbl_extend('force', new, {commit=record.commit})  -- same anchor: keep the commit it was taken at
            end
            local loaded_status = loaded_statuses and loaded_statuses[record.id]
            if new.kind == 'note' and loaded_status ~= nil and (new.status or false) == loaded_status then
                new = vim.deepcopy(new)
                new.status = record.status  -- not changed here: keep theirs
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
        local loaded = loaded_texts and loaded_texts[record.id]
        local edited_here = record.kind == 'note' and loaded and not vim.deep_equal(record.text, loaded)
        local deleted_elsewhere = on_disk and on_disk[record.id] and not edited_here
        if not seen[record.id] and not deleted_elsewhere then
            table.insert(merged, record)
            changed = true
        end
    end
    return merged, changed
end

--- Change a record's text and/or status, or delete it (text=nil and no status)
function M.edit_record(store_path, id, text, status)
    local records = M.load(store_path)
    for i, record in ipairs(records) do
        if record.id == id then
            if text or status then
                if text then record.text = text end
                if status then record.status = status end
            else
                table.remove(records, i)
            end
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
    -- note 3 was deleted by an agent after this nvim loaded it: not written back
    local on_disk_now = {records[1], records[2]}
    local after = M.merge_file(on_disk_now, 'jobs/common.py', {records[1], records[3]}, known,
                               {[records[3].id]=records[3].text}, {[records[1].id]=true, [records[3].id]=true})
    eq(#after, 2, 'record deleted elsewhere stays deleted')
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

function M.test_new_id_unique()
    local seen = {}
    for _ = 1, 2000 do
        local id = M.new_id()
        assert(not seen[id], 'duplicate id ' .. id)
        seen[id] = true
    end
end

function M.test_append_log()
    local tmp_dir = vim.fn.tempname()
    local store_path = tmp_dir .. '/' .. M.FILE_NAME
    local a = {id='aaaa0001', file='src/a.lua', kind='note', text={'why?'}, row=3, line='x = 1', above={}, below={}}
    local b = {id='bbbb0002', file='src/a.lua', kind='mark', char='a', row=5, line='y = 2', above={}, below={}}
    M.save(store_path, {a, b})
    local a2 = vim.deepcopy(a)
    a2.status = 'todo'
    a2.text = {'why?', '--', 'Bot reply:', 'because'}
    M.save(store_path, {a2})  -- a updated, b deleted
    M.save(store_path, {a2})  -- no change: nothing logged
    local log = vim.tbl_map(vim.json.decode, vim.fn.readfile(M.log_path(store_path)))
    eq(vim.tbl_map(function(e) return e.op .. ' ' .. e.id end, log), {'add aaaa0001', 'add bbbb0002', 'update aaaa0001', 'delete bbbb0002'}, 'one line per change')
    eq(log[3].before.text, 'why?', 'update keeps the old text')
    eq(log[3].after.text, 'why?\n--\nBot reply:\nbecause', 'and the new text')
    eq(log[3].after.status, 'todo', 'and the new status')
    eq(log[4].before.char, 'a', 'delete keeps the whole record')
    eq(log[1].ts:match('^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d%.%d%d%dZ$') ~= nil, true, 'UTC timestamp with ms')
    vim.fn.delete(tmp_dir, 'rf')
end

function M.test_status_from_prefixes()
    local function conv(text) return M.status_from_prefixes({kind='note', text=text}) end
    eq(conv({'(⏺) why?', '--', 'Bot reply:'}), {kind='note', status='todo', text={'why?', '--', 'Bot reply:'}}, 'todo')
    eq(conv({'(ok) what is it?'}), {kind='note', status='done', text={'what is it?'}}, 'ok = done')
    eq(conv({'(#) main entry'}), {kind='note', status='anchor', text={'main entry'}}, 'anchor')
    eq(conv({'(-) main entry'}), {kind='note', status='anchor', text={'main entry'}}, 'old anchor symbol')
    eq(conv({'(ok) (⏺) why?'}), {kind='note', status='done', text={'why?'}}, 'done wins over todo')
    eq(M.status_from_prefixes({kind='note', status='read', text={'x'}}).status, 'done', 'old read status renamed')
    eq(M.status_from_prefixes({kind='note', status='answered', text={'x'}}).status, 'todo', 'old answered status renamed')
    eq(M.status_from_prefixes({kind='note', status='archived', text={'x'}}).status, 'done', 'old archived status renamed')
    eq(conv({'(note) not a status'}), {kind='note', text={'(note) not a status'}}, 'unknown tag left in the text')
    eq(conv({'plain'}), {kind='note', text={'plain'}}, 'no prefix: no status (open)')
    eq(M.status_from_prefixes({kind='note', status='open', text={'(⏺) x'}}).text, {'(⏺) x'}, 'has a status already: untouched')
end

return M
