-- Runs every test in tests/test_*.lua: nvim -l tests/run.lua
local tests_dir = vim.fs.dirname(vim.fs.normalize(vim.fn.fnamemodify(arg[0], ':p')))
vim.opt.rtp:prepend(vim.fs.dirname(tests_dir))
package.path = tests_dir .. '/?.lua;' .. package.path
local failed = 0
local files = vim.fn.glob(tests_dir .. '/test_*.lua', false, true)
table.sort(files)
for _, file in ipairs(files) do
    local name = vim.fn.fnamemodify(file, ':t:r')
    local tests = require(name)
    local names = vim.tbl_keys(tests)
    table.sort(names)
    for _, fn in ipairs(names) do
        local ok, err = pcall(tests[fn])
        print(string.format('%s %s.%s%s', ok and 'PASS' or 'FAIL', name, fn, ok and '' or ('\n    ' .. tostring(err))))
        if not ok then failed = failed + 1 end
    end
end
os.exit(failed == 0 and 0 or 1)
