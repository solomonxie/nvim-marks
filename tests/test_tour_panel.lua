-- Tests for nvim-marks.tour_panel: nvim -l tests/run.lua
local M = require('nvim-marks.tour_panel')
local T = {}

local function eq(actual, expected, msg)
    assert(vim.deep_equal(actual, expected), string.format('%s: expected %s, got %s', msg, vim.inspect(expected), vim.inspect(actual)))
end

function T.test_wrap_chunks()
    local function texts(lines)
        return vim.tbl_map(function(l) return table.concat(vim.tbl_map(function(c) return c[1] end, l)) end, lines)
    end
    eq(texts(M.wrap_chunks({{'one two three four', 'Comment'}}, 9)), {'one two ', 'three ', 'four'}, 'wrapped at spaces')
    local lines = M.wrap_chunks(M.text_chunks('calls `save()` then exits', 'Comment'), 12)
    eq(texts(lines), {'calls save()', 'then exits'}, 'code span kept, backticks dropped')
    eq(lines[1][2], {'save()', '@markup.raw.markdown_inline'}, 'code span highlighted')
    eq(texts(M.wrap_chunks({{'abcdefghij', 'Comment'}}, 4)), {'abcd', 'efgh', 'ij'}, 'long word cut')
    eq(texts(M.wrap_chunks({}, 10)), {''}, 'empty line stays a line')
end

function T.test_step_location()
    eq(M.step_location('src/store.lua', 5), 'store.lua:5', 'file in this repo: name only')
    local other = vim.fn.expand('~') .. '/workspace/other-repo/src/a.ts'
    eq(M.step_location(other, 40), '~/workspace/other-repo/src/a.ts:40', 'file in another repo: full path')
    eq(M.step_location('/opt/x/b.py', nil), '/opt/x/b.py:?', 'outside home: absolute path')
end

return T
