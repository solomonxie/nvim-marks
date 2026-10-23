-- Tests for nvim-marks.marks_file: nvim -l tests/run.lua
local M = require('nvim-marks.marks_file')
local T = {}
local convert_old_json = M.convert_old_json

local function fixture_path(name)
    return vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2)) .. '/fixtures/' .. name
end

local function eq(actual, expected, msg)
    assert(vim.deep_equal(actual, expected), string.format('%s: expected %s, got %s', msg, vim.inspect(expected), vim.inspect(actual)))
end

function T.test_store_path()
    local info = {top='/w/myapp-fix', repo='myapp'}
    M.dir_option = '/marks'
    eq(M.store_path(info), '/marks/myapp/marks.jsonl', 'dir')
    M.dir_option = nil
end

function T.test_tours_dir()
    M.dir_option = '/notes'
    eq({M.tours_dir('/w/myapp-fix/a.lua', {top='/w/myapp-fix', repo='myapp'})}, {'/notes/myapp/myapp-fix', 'myapp-fix'}, 'worktree: its own folder')
    eq({M.tours_dir('/w/myapp/a.lua', {top='/w/myapp', repo='myapp'})}, {'/notes/myapp'}, 'main checkout: the whole repo')
    eq({M.tours_dir('/notes/myapp/myapp-fix/plan.md', {top='/notes/myapp', repo='myapp'})}, {'/notes/myapp'}, 'work file: the whole repo')
    M.dir_option = nil
end

function T.test_work_files_repo()
    M.dir_option = '/notes'
    eq(M.work_files_repo('/notes/myapp/myapp-fix-login/plan.md'), {top='/notes/myapp', repo='myapp'}, 'work file')
    eq(M.work_files_repo('/notes/nvim-marks-README.md'), nil, 'file directly in the folder')
    eq(M.work_files_repo('/w/myapp/a.lua'), nil, 'outside the folder')
    M.dir_option = nil
end

function T.test_file_key()
    local info = {top='/w/myapp'}
    eq(M.file_key('/w/myapp/src/a.lua', info), 'src/a.lua', 'inside repo')
    eq(M.file_key('/other/b.lua', info), '/other/b.lua', 'outside repo')
end

function T.test_load_and_encode()
    local records = M.load(fixture_path('marks.jsonl'))
    eq(#records, 3, 'one record per line')
    eq(records[1].text, {'why fetch it again?'}, 'note text')
    eq(records[3].text, {'two', 'lines'}, 'one string in the file, lines in memory')
    eq(records[3].line, '    return "job"', 'code line as it was')
    local lines = vim.fn.readfile(fixture_path('marks.jsonl'))
    for i, record in ipairs(records) do eq(M.encode_record(record), lines[i], 'line ' .. i .. ' written back as it was') end
end

function T.test_merge_file_keeps_places()
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
function T.test_merge_file_keeps_text_edited_elsewhere()
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

--- A record moved to another file elsewhere (an agent) while this nvim had it open stays moved
function T.test_merge_file_keeps_move_elsewhere()
    local records = M.load(fixture_path('marks.jsonl'))
    local id = records[1].id
    local in_nvim = vim.deepcopy(records[1])  -- still in jobs/common.py here
    local on_disk = vim.deepcopy(records)
    on_disk[1].file, on_disk[1].row, on_disk[1].line = 'jobs/other.py', 7, 'def other('
    local loaded = {[id]=records[1].text}
    local merged, changed = M.merge_file(on_disk, 'jobs/common.py', {in_nvim, records[3]}, {[id]=true, [records[3].id]=true},
                                         loaded, {[id]=true}, {[id]=false}, {[id]='jobs/common.py'})
    eq({merged[1].file, merged[1].row, merged[1].line}, {'jobs/other.py', 7, 'def other('}, 'move kept')
    eq(#merged, 3, 'not written back here as well')
    eq(changed, false, 'nothing to write')
end

--- This buffer's file was renamed: the record on disk still has the old key, it moves to the new one
function T.test_merge_file_follows_rename()
    local records = M.load(fixture_path('marks.jsonl'))
    local id = records[1].id
    local renamed = vim.deepcopy(records[1])
    renamed.file = 'jobs/shared.py'
    local merged, changed = M.merge_file(records, 'jobs/shared.py', {renamed}, {[id]=true},
                                         {[id]=records[1].text}, {[id]=true}, {[id]=false}, {[id]='jobs/common.py'})
    eq({merged[1].id, merged[1].file}, {id, 'jobs/shared.py'}, 'moved to the new key, same place')
    eq(changed, true, 'written')
    local unknown = M.merge_file(records, 'jobs/shared.py', {renamed}, {[id]=true})
    eq(unknown[1].file, 'jobs/shared.py', 'no loaded file known: still a rename')
end

--- A note edited here and moved elsewhere meanwhile: the move is kept, with the text and status edited here
function T.test_merge_file_move_elsewhere_keeps_edit_here()
    local records = M.load(fixture_path('marks.jsonl'))
    local id = records[1].id
    local in_nvim = vim.deepcopy(records[1])
    in_nvim.text, in_nvim.status = {'why fetch it again?', 'edited here'}, 'todo'
    local on_disk = vim.deepcopy(records)
    on_disk[1].file, on_disk[1].row = 'jobs/other.py', 7
    local merged, changed = M.merge_file(on_disk, 'jobs/common.py', {in_nvim}, {[id]=true},
                                         {[id]=records[1].text}, {[id]=true}, {[id]=false}, {[id]='jobs/common.py'})
    eq({merged[1].file, merged[1].row}, {'jobs/other.py', 7}, 'location from the move')
    eq({merged[1].text, merged[1].status}, {in_nvim.text, 'todo'}, 'text and status from here')
    eq(changed, true, 'written')
end

function T.test_convert_old_json()
    local records = convert_old_json(fixture_path('marks-history-v3.json'))
    eq(#records, 2, 'every note and mark converted')
    eq({records[1].kind, records[1].text, records[1].row}, {'note', {'one', 'two'}, 2}, 'note')
    eq({records[2].file, records[2].kind, records[2].char}, {'a.lua', 'mark', 'b'}, 'orphan mark')
    eq(#records[2].above, 1, 'v2 context lines turned into hashes')
end

function T.test_new_id_unique()
    local seen = {}
    for _ = 1, 2000 do
        local id = M.new_id()
        assert(not seen[id], 'duplicate id ' .. id)
        seen[id] = true
    end
end

function T.test_append_log()
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

function T.test_status_from_prefixes()
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

return T
