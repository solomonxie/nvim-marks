-- Tests for nvim-marks.anchor: nvim -l tests/run.lua
local M = require('nvim-marks.anchor')
local T = {}
local HASH_LEN = M.HASH_LEN
local function read_fixture(name)
    local dir = vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2)) .. '/fixtures/'
    return vim.fn.readfile(dir .. name)
end

local function eq(actual, expected, msg)
    assert(actual == expected, string.format('%s: expected %s, got %s', msg, vim.inspect(expected), vim.inspect(actual)))
end

function T.test_similarity()
    eq(M.similarity('haha', 'haha'), 1, 'identical')
    eq(M.similarity('haha', 'hiha'), 0.75, 'one char changed')
    eq(M.similarity('haha', 'lolo'), 0, 'different')
    eq(M.similarity('', 'abc'), 0, 'empty')
end

function T.test_anchor_is_small()
    local old = read_fixture('v1.lua')
    local a = M.make(old, 8)
    eq(a.line, 'local function save(data)', 'keeps the line text')
    eq(#a.above + #a.below, 4, 'two hashes above and below')
    eq(#a.above[1], HASH_LEN, 'short hashes')
end

function T.test_locate()
    local old, new = read_fixture('v1.lua'), read_fixture('v2.lua')
    local hashes = {}
    -- `local function save(data)` is line 8 in v1 and line 11 in v2 (3 lines inserted above)
    eq(M.locate(M.make(old, 8), new, hashes), 11, 'moved line found by exact text')
    eq(M.locate(M.make(old, 1), new, hashes), 1, 'unchanged row')
    -- `return nil` appears twice in each version, the surroundings pick the right one
    eq(M.locate(M.make(old, 16), new, hashes), 19, 'duplicate text resolved by context')
    eq(M.locate(M.make(old, 20), new, hashes), 23, 'other duplicate resolved by context')
    -- `print('saving', path)` became `print('saving file', path)` in v2
    eq(M.locate(M.make(old, 10), new, hashes), 13, 'edited line found by fuzzy match')
end

function T.test_locate_copied_block()
    -- After a pull, the noted line exists twice: the old row now holds the copy, the original moved down
    local old = {'def orders():', '    x = 1', '    result = run(', '        trigger=Now(),', '    )', '', 'def creative():'}
    local new = {'def orders():', '    x = 1', '    result = run(', '        trigger=Now(),', '    )', '',
                 'def creative():', '    y = 2', '    result = run(', '        trigger=Now(),', '    )'}
    -- saved on creative's `result = run(` (row 3 in a file where creative came first)
    local saved = M.make({'def creative():', '    y = 2', '    result = run(', '        trigger=Now(),', '    )'}, 3)
    eq(M.locate(saved, new), 9, 'surroundings pick the right copy, not the old row')
    eq(M.locate(M.make(old, 3), new), 3, 'a note that was on the first copy stays there')
end

function T.test_locate_without_context()
    local new = read_fixture('v2.lua')
    -- a hand-written anchor (no hashes) on a line that was edited: `print('saving', path)` → `print('saving file', path)`
    eq(M.locate({row=10, line="    print('saving', path)", above={}, below={}}, new), 13, 'edited line found by text alone')
    eq(M.locate({row=10, line='something that is nowhere', above={}, below={}}, new), nil, 'no match: nil')
end

function T.test_locate_orphan()
    local old, new = read_fixture('v1.lua'), read_fixture('v2.lua')
    -- `local DEBUG = os.getenv('DEBUG')` was deleted in v2
    eq(M.locate(M.make(old, 3), new), nil, 'deleted line is an orphan')
end

function T.test_map_row()
    local old, new = read_fixture('v1.lua'), read_fixture('v3.lua')
    -- v3 adds 2 comment lines at the top, deletes `local DEBUG = ...` and rewrites `local function save(data)`
    eq(M.map_row(old, new, 8), 9, 'rewritten line: the line that replaced it')
    eq(M.map_row(old, new, 14), 15, 'unchanged line below: shifted')
    eq(M.map_row(old, new, 3), nil, 'deleted line: nil')
    eq(M.locate(M.make(old, 8), new), nil, 'the anchor alone loses the rewritten line')
end

function T.test_upgrade_v2_anchor()
    local old, new = read_fixture('v1.lua'), read_fixture('v2.lua')
    local v2 = {row=16, line=old[16], before={old[14], old[15]}, after={old[17], old[18]}}
    eq(M.locate(M.upgrade(v2), new), 19, 'old anchor still resolves after upgrade')
    eq(v2.before, nil, 'full lines dropped')
end

return T
