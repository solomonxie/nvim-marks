local M = require('nvim-marks.utils')

-- Mock Neovim functions used in smart_match
_G.vim = _G.vim or {}
vim.api = vim.api or {}
vim.fn = vim.fn or {}
vim.api.nvim_buf_line_count = function() return 10 end
vim.api.nvim_buf_get_name = function() return "test.lua" end
vim.fn.fnamemodify = function(n) return n end

local function assert_eq(actual, expected, msg)
    if actual == expected then
        print("PASS: " .. msg)
    else
        print("FAIL: " .. msg .. " (Expected " .. tostring(expected) .. ", got " .. tostring(actual) .. ")")
        os.exit(1)
    end
end

-- Test Levenshtein
print("Testing Levenshtein Distance (Similarity)...")
assert_eq(M.levenshtein_distance("haha", "haha"), 100, "identical strings")
assert_eq(M.levenshtein_distance("haha", "hiha"), 75, "one char change")
assert_eq(M.levenshtein_distance("haha", "lolo"), 0, "completely different")
assert_eq(M.levenshtein_distance("", "abc"), 0, "empty string")

-- Test Smart Match
print("\nTesting Smart Match Logic...")

-- Prepare Mock Data
M.BlameCache = {
    ["test.lua"] = {
        [1] = { content = "line 1", percentile = 10, prev = "", next = "line 2" },
        [2] = { content = "line 2", percentile = 20, prev = "line 1", next = "line 3" },
        [3] = { content = "line 3", percentile = 30, prev = "line 2", next = "line 4" },
        [5] = { content = "line 3 (moved)", percentile = 50, prev = "line x", next = "line y" }, -- Slightly modified and moved
    }
}
M.RenameHistory = {}

local old_blame = { content = "line 3", percentile = 30, prev = "line 2", next = "line 4" }

-- 1. Identical match at same row
assert_eq(M.smart_match(1, 3, "test.lua", old_blame), 3, "exact match at same row")

-- 2. Match moved to different row
local moved_blame = { content = "line 3", percentile = 30, prev = "line 2", next = "line 4" }
-- Clear old entry to force scanning
M.BlameCache["test.lua"][3] = { content = "something else", percentile = 30 }
-- Put "line 3" at row 8
M.BlameCache["test.lua"][8] = { content = "line 3", percentile = 80, prev = "line 2", next = "line 4" }
vim.api.nvim_buf_line_count = function() return 10 end

assert_eq(M.smart_match(1, 3, "test.lua", moved_blame), 8, "match moved to row 8")

-- 3. Renamed file
M.RenameHistory["old.lua"] = { "test.lua" }
assert_eq(M.smart_match(1, 1, "old.lua", { content = "line 1", percentile = 10 }), 1, "match in renamed file")

print("\nAll unit tests passed!")
