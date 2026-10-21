-- Runs every `test_*` function in the plugin's modules: nvim -l tests/run.lua
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(arg[0] and vim.fn.fnamemodify(arg[0], ':p') or '')))
vim.opt.rtp:prepend(root)
local failed = 0
for _, name in ipairs({'nvim-marks.anchor', 'nvim-marks.store', 'nvim-marks.utils', 'nvim-marks'}) do
    local mod = require(name)
    local names = vim.tbl_filter(function(k) return k:match('^test_') end, vim.tbl_keys(mod))
    table.sort(names)
    for _, fn in ipairs(names) do
        local ok, err = pcall(mod[fn])
        print(string.format('%s %s.%s%s', ok and 'PASS' or 'FAIL', name, fn, ok and '' or ('\n    ' .. tostring(err))))
        if not ok then failed = failed + 1 end
    end
end
os.exit(failed == 0 and 0 or 1)
