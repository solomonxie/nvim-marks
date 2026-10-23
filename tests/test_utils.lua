-- Tests for nvim-marks.utils: nvim -l tests/run.lua
local M = require('nvim-marks.utils')
local T = {}
local anchor = require('nvim-marks.anchor')
local marks_file = require('nvim-marks.marks_file')
local git_lib = require('nvim-marks.git')

local function read_fixture(name)
    local dir = vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2)) .. '/fixtures/'
    return vim.fn.readfile(dir .. name)
end

local function eq(actual, expected, msg)
    assert(vim.deep_equal(actual, expected), string.format('%s: expected %s, got %s', msg, vim.inspect(expected), vim.inspect(actual)))
end

--- Save marks on v1, switch the file to v2 (like changing branch) and back, marks follow the lines
function T.test_save_restore_across_versions()
    local tmp_dir = vim.fn.tempname()
    vim.fn.mkdir(tmp_dir, 'p')
    marks_file.dir_option = tmp_dir
    local path = tmp_dir .. '/f.lua'
    vim.fn.writefile(read_fixture('v1.lua'), path)
    local bufnr = vim.fn.bufadd(path)
    vim.fn.bufload(bufnr)
    M.set_vimmark(bufnr, 'a', 8)  -- local function save(data)
    M.set_vimmark(bufnr, 'b', 3)  -- local DEBUG = ..., deleted in v2
    M.set_note(bufnr, 10, {'check path'})  -- print('saving', path)
    M.save_all(bufnr)
    local function reopen(fixture)
        vim.api.nvim_buf_delete(bufnr, {force=true})
        vim.fn.writefile(read_fixture(fixture), path)
        bufnr = vim.fn.bufadd(path)
        vim.fn.bufload(bufnr)
        M.restore_marks(bufnr)
    end
    reopen('v2.lua')
    eq(vim.api.nvim_buf_get_mark(bufnr, 'a')[1], 11, 'mark follows the line')
    eq(vim.api.nvim_buf_get_mark(bufnr, 'b')[1], 0, 'mark on deleted line not placed')
    eq(M.Orphans[bufnr][1].char, 'b', 'mark on deleted line kept as orphan')
    eq(M.scan_notes(bufnr)[1][2], 13, 'note follows the edited line')
    eq(M.scan_notes(bufnr)[1][3], {'check path'}, 'note text kept')
    M.save_all(bufnr)
    reopen('v1.lua')
    eq(vim.api.nvim_buf_get_mark(bufnr, 'b')[1], 3, 'orphan comes back with its line')
    eq(vim.api.nvim_buf_get_mark(bufnr, 'a')[1], 8, 'mark back on v1')
    eq(M.scan_notes(bufnr)[1][2], 10, 'note back on v1, no drift')
    vim.api.nvim_buf_delete(bufnr, {force=true})
    marks_file.dir_option = nil
    vim.fn.delete(tmp_dir, 'rf')
end

--- A note whose line was rewritten, and a file renamed, are found again through the commit saved with the note
function T.test_relocate_by_commit()
    local tmp_dir = vim.fn.resolve(vim.fn.tempname())
    vim.fn.mkdir(tmp_dir .. '/repo', 'p')
    marks_file.dir_option = tmp_dir .. '/marks'
    local repo = tmp_dir .. '/repo'
    local function git(...) vim.system(vim.list_extend({'git', '-C', repo, '-c', 'user.name=t', '-c', 'user.email=t@t'}, {...})):wait() end
    git('init', '-q')
    vim.fn.writefile(read_fixture('v1.lua'), repo .. '/f.lua')
    git('add', '.')
    git('commit', '-qm', 'v1')
    local bufnr = vim.fn.bufadd(repo .. '/f.lua')
    vim.fn.bufload(bufnr)
    M.set_note(bufnr, 8, {'why encode here?'})  -- local function save(data)
    M.save_all(bufnr)
    local saved = marks_file.load(marks_file.store_path(git_lib.repo_info(repo .. '/f.lua')))[1]
    eq(#saved.commit, git_lib.COMMIT_LEN, 'commit saved with the note')
    vim.api.nvim_buf_delete(bufnr, {force=true})
    -- v3 rewrites that line to `local function write_payload(payload, opts)`, and the file is renamed
    git('mv', 'f.lua', 'g.lua')
    vim.fn.writefile(read_fixture('v3.lua'), repo .. '/g.lua')
    git('add', '.')
    git('commit', '-qm', 'v3')
    bufnr = vim.fn.bufadd(repo .. '/g.lua')
    vim.fn.bufload(bufnr)
    M.restore_marks(bufnr)
    local notes = M.scan_notes(bufnr)
    eq(#notes, 1, 'note followed the rename')
    eq(notes[1][2], 9, 'and the rewritten line')
    M.save_all(bufnr)
    local records = marks_file.load(marks_file.store_path(git_lib.repo_info(repo .. '/g.lua')))
    eq({#records, records[1].file}, {1, 'g.lua'}, 'saved under the new name, same record')
    vim.api.nvim_buf_delete(bufnr, {force=true})
    marks_file.dir_option = nil
    vim.fn.delete(tmp_dir, 'rf')
end

--- In the JSONL store a new note is one appended line, and a note that moved rewrites only its own line
function T.test_store_lines_change_one_at_a_time()
    local tmp_dir = vim.fn.tempname()
    vim.fn.mkdir(tmp_dir, 'p')
    marks_file.dir_option = tmp_dir
    local path = tmp_dir .. '/f.lua'
    vim.fn.writefile(read_fixture('v1.lua'), path)
    local store_path = tmp_dir .. '/_no_repo/' .. marks_file.FILE_NAME
    local bufnr = vim.fn.bufadd(path)
    vim.fn.bufload(bufnr)
    M.set_note(bufnr, 8, {'first'})
    M.save_all(bufnr)
    local before = vim.fn.readfile(store_path)
    M.set_note(bufnr, 14, {'second'})
    M.save_all(bufnr)
    local after = vim.fn.readfile(store_path)
    eq(#after, 2, 'appended')
    eq(after[1], before[1], 'first note line untouched')
    -- reopen on v2: `first` moves from row 8 to 11, `second` from 14 to 17
    vim.api.nvim_buf_delete(bufnr, {force=true})
    vim.fn.writefile(read_fixture('v2.lua'), path)
    bufnr = vim.fn.bufadd(path)
    vim.fn.bufload(bufnr)
    M.restore_marks(bufnr)
    M.save_all(bufnr)
    local moved = vim.fn.readfile(store_path)
    eq(#moved, 2, 'still one line per note')
    eq(vim.json.decode(moved[1]).id, vim.json.decode(after[1]).id, 'same record kept its place')
    eq(vim.json.decode(moved[1]).row, 11, 'row updated in place')
    vim.api.nvim_buf_delete(bufnr, {force=true})
    marks_file.dir_option = nil
    vim.fn.delete(tmp_dir, 'rf')
end

--- A file changed outside nvim (e.g. `git pull`) and reloaded: notes follow their lines, the saved anchors aren't blanked
function T.test_outside_change_reload()
    local tmp_dir = vim.fn.tempname()
    vim.fn.mkdir(tmp_dir, 'p')
    marks_file.dir_option = tmp_dir
    local path = tmp_dir .. '/f.lua'
    vim.fn.writefile(read_fixture('v1.lua'), path)
    vim.cmd('runtime plugin/nvim-marks.vim')  -- the autocmd that restores notes after a reload
    vim.cmd('edit ' .. path)
    local bufnr = vim.api.nvim_get_current_buf()
    M.set_note(bufnr, 8, {'save'})  -- local function save(data)
    M.save_all(bufnr)
    vim.o.autoread = true
    vim.fn.writefile(read_fixture('v2.lua'), path)  -- 3 lines inserted above it
    vim.uv.fs_utime(path, os.time() + 5, os.time() + 5)  -- make sure nvim sees a newer file
    vim.cmd('checktime')
    eq(vim.api.nvim_buf_get_lines(bufnr, 10, 11, false)[1], 'local function save(data)', 'buffer reloaded from disk')
    eq(M.scan_notes(bufnr)[1][2], 11, 'note moved with its line')
    local saved = marks_file.load(tmp_dir .. '/_no_repo/' .. marks_file.FILE_NAME)[1]
    eq(saved.line, 'local function save(data)', 'saved anchor not blanked by the reload')
    vim.cmd('bwipeout!')
    marks_file.dir_option = nil
    vim.fn.delete(tmp_dir, 'rf')
end

--- Saving twice (e.g. `save_all(0)`, then leaving the buffer) keeps one line per note in the store
function T.test_save_twice_no_duplicates()
    local tmp_dir = vim.fn.tempname()
    vim.fn.mkdir(tmp_dir, 'p')
    marks_file.dir_option = tmp_dir
    local path = tmp_dir .. '/f.lua'
    vim.fn.writefile(read_fixture('v1.lua'), path)
    vim.cmd('edit ' .. path)
    local bufnr = vim.api.nvim_get_current_buf()
    M.set_note(0, 8, {'once'})
    M.save_all(0)
    M.save_all(bufnr)
    eq(#vim.fn.readfile(tmp_dir .. '/_no_repo/' .. marks_file.FILE_NAME), 1, 'one record')
    vim.cmd('bwipeout!')
    marks_file.dir_option = nil
    vim.fn.delete(tmp_dir, 'rf')
end

function T.test_toggle_note_text()
    local bufnr = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, read_fixture('v1.lua'))
    M.set_note(bufnr, 8, {'a note'})
    local function shown() return vim.api.nvim_buf_get_extmarks(bufnr, M.NS_Notes, 0, -1, {details=true})[1][4].virt_text ~= nil end
    eq(shown(), true, 'shown by default')
    M.toggle_note_text()
    eq(shown(), false, 'hidden')
    eq(M.scan_notes(bufnr)[1][3], {'a note'}, 'note kept with its text')
    eq(M.scan_notes(bufnr)[1][2], 8, 'note kept on its line')
    M.toggle_note_text()
    eq(shown(), true, 'shown again')
    vim.api.nvim_buf_delete(bufnr, {force=true})
end

function T.test_merge_note_edit()
    local before = {'why?'}
    local latest = {'(⏺) why?', '--', 'Bot reply:', 'because'}
    eq(M.merge_note_edit(before, latest, {'why?', '-- and how?'}), {'(⏺) why?', '--', 'Bot reply:', 'because', '-- and how?'},
       'appended line goes after the reply written meanwhile')
    eq(M.merge_note_edit(before, latest, {'why not?'}), {'why not?'}, 'a rewrite wins')
end

--- An agent edits the store while nvim has the file open: nvim's next save keeps the agent's reply, its deletion
--- and its new note, and the buffer then shows them
function T.test_save_keeps_changes_made_elsewhere()
    local tmp_dir = vim.fn.tempname()
    vim.fn.mkdir(tmp_dir, 'p')
    marks_file.dir_option = tmp_dir
    local path = tmp_dir .. '/f.lua'
    local store_path = tmp_dir .. '/_no_repo/' .. marks_file.FILE_NAME
    vim.fn.writefile(read_fixture('v1.lua'), path)
    vim.cmd('edit ' .. path)
    local bufnr = vim.api.nvim_get_current_buf()
    M.set_note(bufnr, 8, {'question A'})
    M.set_note(bufnr, 10, {'question B'})
    M.save_all(bufnr)
    vim.uv.sleep(5)  -- a later mtime for the agent's write
    -- the agent: replies to A, deletes B, adds C (like the marks skill does: rewrite the file)
    local records = marks_file.load(store_path)
    local a = vim.tbl_filter(function(r) return r.text[1] == 'question A' end, records)[1]
    a.status = 'todo'
    a.text = {'question A', '--', 'Bot reply:', 'answer'}
    local new = {id='agent001', file=a.file, kind='note', text={'from agent'}, row=3, line=a.line, above={}, below={}}
    marks_file.save(store_path, {a, new})
    M.save_all(bufnr)
    local texts = vim.tbl_map(function(r) return r.text[1] end, marks_file.load(store_path))
    eq(texts, {'question A', 'from agent'}, 'reply kept, deletion kept, new note kept')
    eq(marks_file.load(store_path)[1].status, 'todo', 'status set elsewhere kept')
    local shown = vim.tbl_map(function(n) return n[3][1] end, M.scan_notes(bufnr))
    table.sort(shown)
    eq(shown, {'from agent', 'question A'}, 'buffer shows the latest')
    vim.cmd('bwipeout!')
    marks_file.dir_option = nil
    vim.fn.delete(tmp_dir, 'rf')
end

--- An agent moves a note to another file while nvim has its file open: nvim's next save doesn't pull it back,
--- and the buffer drops it
function T.test_save_keeps_note_moved_elsewhere()
    local tmp_dir = vim.fn.tempname()
    vim.fn.mkdir(tmp_dir, 'p')
    marks_file.dir_option = tmp_dir
    local path = tmp_dir .. '/f.lua'
    local store_path = tmp_dir .. '/_no_repo/' .. marks_file.FILE_NAME
    vim.fn.writefile(read_fixture('v1.lua'), path)
    vim.cmd('edit ' .. path)
    local bufnr = vim.api.nvim_get_current_buf()
    M.set_note(bufnr, 8, {'to move'})
    M.set_note(bufnr, 10, {'stays'})
    M.save_all(bufnr)
    vim.uv.sleep(5)  -- a later mtime for the agent's write
    local records = marks_file.load(store_path)
    for _, r in ipairs(records) do
        if r.text[1] == 'to move' then r.file, r.row, r.line = tmp_dir .. '/g.lua', 3, 'x = 1' end
    end
    marks_file.save(store_path, records)
    M.reload_if_changed(bufnr)
    local moved = vim.tbl_filter(function(r) return r.text[1] == 'to move' end, marks_file.load(store_path))[1]
    eq({moved.file, moved.row}, {tmp_dir .. '/g.lua', 3}, 'move kept on disk')
    eq(#marks_file.load(store_path), 2, 'not written back to f.lua')
    eq(vim.tbl_map(function(n) return n[3][1] end, M.scan_notes(bufnr)), {'stays'}, 'buffer dropped the moved note')
    M.save_all(bufnr)
    eq(#marks_file.load(store_path), 2, 'later saves leave it alone')
    vim.cmd('bwipeout!')
    marks_file.dir_option = nil
    vim.fn.delete(tmp_dir, 'rf')
end

--- A note emptied to nothing or only spaces (in the editor, by an agent or by hand) counts as deleted
function T.test_empty_note_is_deleted()
    eq(M.is_empty_note({'', '   ', '\t'}), true, 'spaces only')
    eq(M.is_empty_note('  \n '), true, 'one string')
    eq(M.is_empty_note({'', 'x'}), false, 'has text')
    local tmp_dir = vim.fn.tempname()
    vim.fn.mkdir(tmp_dir, 'p')
    marks_file.dir_option = tmp_dir
    local path = tmp_dir .. '/f.lua'
    local store_path = tmp_dir .. '/_no_repo/' .. marks_file.FILE_NAME
    vim.fn.writefile(read_fixture('v1.lua'), path)
    vim.cmd('edit ' .. path)
    local bufnr = vim.api.nvim_get_current_buf()
    M.set_note(bufnr, 8, {'keep'})
    M.set_note(bufnr, 10, {'to empty'})
    M.save_all(bufnr)
    -- emptied in the file (by an agent or by hand)
    local records = marks_file.load(store_path)
    for _, r in ipairs(records) do if r.text[1] == 'to empty' then r.text = {'  ', ''} end end
    marks_file.save(store_path, records)
    M.restore_marks(bufnr)
    eq(#M.scan_notes(bufnr), 1, 'empty note not shown')
    M.save_all(bufnr)
    eq(vim.tbl_map(function(r) return r.text[1] end, marks_file.load(store_path)), {'keep'}, 'empty note removed from the file')
    vim.cmd('bwipeout!')
    marks_file.dir_option = nil
    vim.fn.delete(tmp_dir, 'rf')
end

function T.test_one_line()
    eq(M.one_line({'(⏺) why?', '--', '', 'Bot reply:', '  because  '}), '(⏺) why? -- Bot reply: because', 'spaces, no blanks')
    eq(M.one_line({'one'}), 'one', 'single line')
end

function T.test_status_prefix_on_code_line()
    local bufnr = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, read_fixture('v1.lua'))
    local open_id = M.set_note(bufnr, 3, {'still a question'})
    local todo_id = M.set_note(bufnr, 8, {'why?', '--', 'Bot reply:', 'because'}, nil, 'todo')
    local function shown(id) return vim.api.nvim_buf_get_extmark_by_id(bufnr, M.NS_Notes, id, {details=true})[3].virt_text[1][1] end
    eq(shown(open_id), M.note_prefix .. 'still a question', 'open: no symbol')
    eq(shown(todo_id), M.note_prefix .. '(⏺) why? -- Bot reply: because', 'todo: symbol in front')
    eq(M.NoteTexts[bufnr][todo_id][1], 'why?', 'symbol not in the saved text')
    M.set_note_status(bufnr, open_id, 'done')
    eq(shown(open_id), M.note_prefix .. '(ok) still a question', 'symbol follows a status change')
    vim.api.nvim_buf_delete(bufnr, {force=true})
end

--- A file shown by peek or a tour is an ordinary buffer: filetype set, listed, in the same window, not split;
--- closing it after moving on leaves only the file shown now
function T.test_show_in_window_opens_like_edit()
    vim.cmd('filetype on')
    local path = vim.fn.tempname() .. '.lua'
    vim.fn.writefile({'local x = 1'}, path)
    local win = vim.api.nvim_get_current_win()
    local windows_before = #vim.api.nvim_list_wins()
    local bufnr, opened = M.show_in_window(win, path)
    eq({vim.bo[bufnr].filetype, vim.bo[bufnr].buflisted, opened}, {'lua', true, true}, 'typed and listed, like :edit')
    eq(vim.api.nvim_win_get_buf(win), bufnr, 'shown in the given window')
    eq(#vim.api.nvim_list_wins(), windows_before, 'no new window')
    local path2 = vim.fn.tempname() .. '.py'
    vim.fn.writefile({'x = 1'}, path2)
    local bufnr2 = M.show_in_window(win, path2)
    eq(vim.bo[bufnr2].filetype, 'python', 'second file typed')
    eq(vim.api.nvim_buf_is_loaded(bufnr), true, 'first file still open')
    M.close_preview_buffer(bufnr2)
    eq(vim.api.nvim_buf_is_loaded(bufnr2), true, 'shown in the window: not closed')
    eq({M.show_in_window(win, path)}, {bufnr, false}, 'back to the same buffer, not opened again')
    M.close_preview_buffer(bufnr2)
    eq(vim.api.nvim_buf_is_loaded(bufnr2), false, 'moved on: closed')
    eq(M.show_in_window(win, '/nonexistent/x.lua'), nil, 'missing file: nil')
    vim.api.nvim_win_set_buf(win, vim.api.nvim_create_buf(true, false))
    for _, b in ipairs({bufnr, bufnr2}) do
        if vim.api.nvim_buf_is_valid(b) then vim.api.nvim_buf_delete(b, {force=true}) end
    end
end

return T
