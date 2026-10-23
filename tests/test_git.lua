-- Tests for nvim-marks.git: nvim -l tests/run.lua
local M = require('nvim-marks.git')
local T = {}

local function eq(actual, expected, msg)
    assert(vim.deep_equal(actual, expected), string.format('%s: expected %s, got %s', msg, vim.inspect(expected), vim.inspect(actual)))
end

function T.test_repo_name()
    eq(M.repo_name('/w/myapp-fix', '/w/myapp/.git'), 'myapp', 'worktree of a normal repo')
    eq(M.repo_name('/home/me/dot', '/home/me/.dot.git'), 'dot', 'separate hidden git dir')
    eq(M.repo_name('/w/myapp-wt', '/srv/myapp.git'), 'myapp', 'bare repo')
end

return T
