-- Tests for nvim-marks: nvim -l tests/run.lua
local M = require('nvim-marks')
local T = {}
local fit = M.fit

function T.test_fit()
    local function eq(a, b, msg) assert(a == b, msg .. ': expected ' .. vim.inspect(b) .. ', got ' .. vim.inspect(a)) end
    eq(fit('short', 8), 'short   ', 'padded')
    eq(fit('exactly8', 8), 'exactly8', 'fits exactly')
    eq(fit(string.rep('a', 500), 10), string.rep('a', 9) .. '…', 'long text cut with …')
    eq(vim.fn.strdisplaywidth(fit('中文中文中文中文', 7)), 7, 'wide characters still fit the width')
end

return T
