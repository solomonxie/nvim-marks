--- The marks file: one JSONL file per repo holds the marks and notes of all its files, shared by every worktree and
--- branch. This module reads, writes and merges it, keeps its change log, and knows the marks folder's layout.
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
--- through the diff from that commit's version of the file, and a renamed file is followed (see utils.lua; git questions are in git.lua).

local M = {}

local git = require('nvim-marks.git')

M.DEFAULT_DIR = vim.fn.stdpath('data') .. '/nvim-marks'
M.dir_option = nil  --- @type string|nil # set by setup()
M.FILE_NAME = 'marks.jsonl'
M.LOG_FILE_NAME = 'marks-log.jsonl'  -- next to the store: every add/update/delete, appended, never rewritten
local KnownRoots = {}  --- @type table<string, table<string, boolean>> # {store_path={root=true}}: checkouts seen this session
local OLD_FILE_NAME = 'marks-history.json'  -- previous format, read once when there's no marks.jsonl yet
local KEY_ORDER = {'id', 'file', 'kind', 'char', 'status', 'text', 'row', 'line', 'above', 'below', 'commit', 'created'}

--- @return string # now, as a record's `created` time: UTC, to the second, sorts as text
function M.now()
    return os.date('!%Y-%m-%dT%H:%M:%SZ')
end

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

--- Where to look for tours from a buffer: a linked worktree's own work-files folder (`<dir>/<repo>/<worktree>`, the
--- checkout's folder name), or the whole `<dir>/<repo>` from the main checkout, a work file, or outside git.
---
--- @param path string # the buffer's file, resolved
--- @return string, string|nil # folder to search (with everything under it), and the worktree name when it's one
function M.tours_dir(path, info)
    local repo_dir = vim.fs.dirname(M.store_path(info))
    if M.work_files_repo(path) or not info.top then return repo_dir, nil end
    local worktree = vim.fs.basename(info.top)
    if worktree == info.repo then return repo_dir, nil end  -- the main checkout: every worktree's tours
    return repo_dir .. '/' .. worktree, worktree
end

--- Remember a checkout of a repo, so its files can be found from a buffer in another checkout or a work file
function M.remember_root(store_path, root)
    if not root then return end
    KnownRoots[store_path] = KnownRoots[store_path] or {}
    KnownRoots[store_path][root] = true
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
    local cwd_info = git.repo_info(vim.fn.getcwd() .. '/.')
    if cwd_info.top and M.store_path(cwd_info) == store_path then add(cwd_info.top) end
    local known = vim.tbl_keys(KnownRoots[store_path] or {})
    table.sort(known)
    for _, root in ipairs(known) do add(root) end
    for _, root in ipairs(vim.list_slice(roots)) do
        for _, wt in ipairs(git.worktrees(root)) do add(wt) end
    end
    if info.repo ~= '_no_repo' then add(marks_dir() .. '/' .. info.repo) end
    return roots
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
--- A record in `current` that's saved under another file on disk is one of two things, told apart by `loaded_files`:
--- - renamed: it's still under the file key this nvim last loaded or saved it under, so this buffer's file was
---   renamed (e.g. `git mv`): this buffer's copy is written, under the new key, in the same place.
--- - moved elsewhere: its file on disk isn't that key, so someone (an agent, another nvim) moved it to another file
---   since: the move is kept and this buffer's copy isn't written back (the buffer then reloads without it).
---   A text or status edited here since loading is carried onto the moved record, so the edit isn't lost: it ends
---   up in the note at its new file. Untouched text and status stay as they are on disk.
--- Without an entry in `loaded_files` (or without `loaded_files`), it's taken as a rename.
---
--- @param loaded_statuses table<string, string|false>|nil # {id=status} as last loaded or saved (false: none)
--- @param loaded_files table<string, string>|nil # {id=file} the file key each record had when last loaded or saved
--- @return table[], boolean # merged records, whether anything changed
function M.merge_file(records, file, current, known, loaded_texts, on_disk, loaded_statuses, loaded_files)
    local by_id = {}
    for _, record in ipairs(current) do by_id[record.id] = record end
    local merged, changed, seen = {}, false, {}
    for _, record in ipairs(records) do
        local loaded_file = loaded_files and loaded_files[record.id]
        if record.file ~= file and by_id[record.id] and loaded_file and record.file ~= loaded_file then
            -- moved to another file elsewhere: keep it there, with any text/status edited here carried along
            local here, kept = by_id[record.id], record
            local loaded = loaded_texts and loaded_texts[record.id]
            if here.kind == 'note' and loaded and not vim.deep_equal(here.text, loaded) then
                kept = vim.tbl_extend('force', kept, {text=here.text})
            end
            local loaded_status = loaded_statuses and loaded_statuses[record.id]
            if here.kind == 'note' and loaded_status ~= nil and (here.status or false) ~= loaded_status then
                kept = vim.deepcopy(kept)
                kept.status = here.status
            end
            if kept ~= record then changed = true end
            table.insert(merged, kept)
            seen[record.id] = true
        elseif record.file ~= file and by_id[record.id] then
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
            if record.created and not new.created then
                new = vim.tbl_extend('force', new, {created=record.created})  -- created once, never changed
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

M.convert_old_json = convert_old_json  -- for tests

return M
