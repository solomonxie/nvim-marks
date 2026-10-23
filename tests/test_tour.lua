-- Tests for nvim-marks.tour: nvim -l tests/run.lua
local M = require('nvim-marks.tour')
local T = {}

local function fixture_path(name)
    return vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2)) .. '/fixtures/' .. name
end

local function eq(actual, expected, msg)
    assert(vim.deep_equal(actual, expected), string.format('%s: expected %s, got %s', msg, vim.inspect(expected), vim.inspect(actual)))
end

function T.test_load()
    local tour = assert(M.load(fixture_path('tours/save-flow.jsonl')))
    eq(tour.name, 'Save flow', 'name')
    eq(tour.root, 's1', 'root')
    eq(#tour.order, 5, 'steps')
    eq(tour.steps.s3.children, {'s4', 's5'}, 'children')
    eq(tour.info, {}, 'no info: empty')
    -- earlier format, a header line before the steps
    local tmp = vim.fn.tempname() .. '.jsonl'
    vim.fn.writefile({'{"tour":"Old","description":"d","root":"b"}', '{"id":"a"}', '{"id":"b","children":["a"]}'}, tmp)
    local old = assert(M.load(tmp))
    eq({old.name, old.description, old.root, #old.order}, {'Old', 'd', 'b', 2}, 'header line still read')
    vim.fn.delete(tmp)
end

function T.test_tree()
    local tour = assert(M.load(fixture_path('tours/save-flow.jsonl')))
    eq(vim.tbl_map(function(r) return string.rep(' ', r.depth) .. r.id .. (r.shared and '*' or '') end, M.tree(tour)),
       {'s1', ' s2', '  s4*', ' s3', '  s5'}, 'each step once, shared marked')
end

function T.test_rejects_bad_tours()
    local tmp = vim.fn.tempname() .. '.jsonl'
    local function check(lines, want)
        vim.fn.writefile(lines, tmp)
        local tour, err = M.load(tmp)
        assert(tour == nil and err and err:find(want, 1, true), 'expected error with "' .. want .. '", got ' .. tostring(err))
    end
    check({'{"id":"a","tour":"t","children":["b"]}', '{"id":"b","children":["a"]}'}, 'cycle through a → b → a')
    check({'{"id":"a","tour":"t","children":["zz"]}'}, 'unknown child zz')
    check({'{"id":"a"}'}, 'no root step')
    check({'{"id":"a","tour":"t"}', '{"id":"b","tour":"u"}'}, 'a second root step')
    check({'{"tour":"t","root":"nope"}', '{"id":"a"}'}, 'root step nope not found')
    check({'{"id":"a","tour":"t"}', '{"id":"a"}'}, 'duplicate id a')
    vim.fn.delete(tmp)
end

function T.test_list()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir .. '/myapp-fix/notes', 'p')
    vim.fn.writefile(vim.fn.readfile(fixture_path('tours/save-flow.jsonl')), dir .. '/myapp-fix/notes/tours-nested.jsonl')
    local nested = M.list(dir)
    eq({#nested, nested[1].folder}, {1, 'myapp-fix/notes'}, 'nested in a worktree folder, folder kept')
    vim.fn.delete(dir .. '/myapp-fix', 'rf')
    vim.fn.writefile(vim.fn.readfile(fixture_path('tours/save-flow.jsonl')), dir .. '/tours-save-flow.jsonl')
    vim.fn.writefile({'not json'}, dir .. '/tours-broken.jsonl')
    local tours = M.list(dir)
    eq(#tours, 2, 'both tour files listed')
    local ok = vim.tbl_filter(function(t) return not t.error end, tours)[1]
    eq({ok.name, ok.steps_count}, {'Save flow', 5}, 'good tour')
    eq(vim.tbl_filter(function(t) return t.error end, tours)[1].error:find('not valid JSON', 1, true) ~= nil, true, 'broken one says why')
    vim.fn.delete(dir, 'rf')
end

--- A line matches the tour step on it, or else a step in the same function (innermost first, then the closest)
function T.test_match_step()
    local tour = assert(M.load(fixture_path('tours/save-flow.jsonl')))
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.fn.readfile(fixture_path('v1.lua')))
    local function match(row) return {M.match_step(tour, 'v1.lua', row, M.scopes_at(bufnr, row))} end
    -- steps: s1 row 1, s2 row 5 (encode), s4 row 6 (inside encode), s3 row 8 (save), s5 row 10 (inside save)
    eq(match(10), {'s5', 'line'}, 'the step on this line')
    eq(match(11), {'s5', 'scope'}, 'a line of save(): the closest step in that function')
    eq(match(9), {'s3', 'scope'}, 'equally close: the earlier step')
    eq(match(7), {'s4', 'scope'}, 'the `end` of encode() belongs to it')
    eq(match(3), {}, 'top-level line with no step on it: no match')
    eq({M.match_step(tour, 'other.lua', 10, {})}, {}, 'another file: no match')
    vim.api.nvim_buf_delete(bufnr, {force=true})
end

--- Tours share the repo's folder with the marks store: only the tour is listed, not marks.jsonl, marks-log.jsonl or a backup

--- A found step's new row and text are written back to its own line; other lines and edits made meanwhile stay
function T.test_update_step()
    local tmp = vim.fn.tempname() .. '.jsonl'
    local lines = vim.fn.readfile(fixture_path('tours/save-flow.jsonl'))
    vim.fn.writefile(lines, tmp)
    eq(M.update_step(tmp, 's3', {row=11, line='local function save(data)'}), true, 'written')
    local after = vim.fn.readfile(tmp)
    eq(#after, #lines, 'same number of lines')
    eq(after[1], lines[1], 'other steps untouched')
    local s3 = vim.json.decode(after[3])
    eq({s3.id, s3.row, s3.title, s3.children}, {'s3', 11, 'save', {'s4', 's5'}}, 'row updated, rest kept')
    eq(after[3]:match('^{"id":"s3","title"') ~= nil, true, 'key order kept')
    eq(M.update_step(tmp, 's3', {row=11}), false, 'no change: not written')
    vim.fn.delete(tmp)
end
function T.test_list_skips_marks_files()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    vim.fn.writefile({'{"id":"a1","file":"x.lua","kind":"note","text":"q","row":1,"line":"x"}'}, dir .. '/marks.jsonl')
    vim.fn.writefile({'{"ts":"2026-10-21T00:00:00Z","op":"add","id":"a1","file":"x.lua"}'}, dir .. '/marks-log.jsonl')
    vim.fn.writefile({'{"id":"a1"}'}, dir .. '/marks.jsonl.bak-20261021')
    vim.fn.writefile(vim.fn.readfile(fixture_path('tours/save-flow.jsonl')), dir .. '/tours-save-flow.jsonl')
    vim.fn.writefile(vim.fn.readfile(fixture_path('tours/save-flow.jsonl')), dir .. '/my-walk.jsonl')
    local names = vim.tbl_map(function(t) return vim.fs.basename(t.path) end, M.list(dir))
    table.sort(names)
    eq(names, {'my-walk.jsonl', 'tours-save-flow.jsonl'}, 'tours only, by name or by header')
    vim.fn.delete(dir, 'rf')
end

--- Tours are listed most recent first, by the root step's `created`
function T.test_list_newest_first()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    local function tour(name, created)
        local root = {id='r', tour=name, created=created, title='Overview'}
        vim.fn.writefile({vim.json.encode(root)}, dir .. '/tours-' .. name .. '.jsonl')
    end
    tour('older', '2026-10-20T10:00:00Z')
    tour('newest', '2026-10-23T10:00:00Z')
    tour('middle', '2026-10-22T10:00:00Z')
    eq(vim.tbl_map(function(t) return t.name end, M.list(dir)), {'newest', 'middle', 'older'}, 'most recent first')
    vim.fn.delete(dir, 'rf')
end

return T
