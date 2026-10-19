--- Find where a saved line is now, after the file changed (edits, branch switch, worktree, rebase).
---
--- Each mark/note keeps an anchor: its row, the line's text and a few lines around it.
--- Each file also keeps a snapshot of its lines at save time. On restore:
--- 1. Map the old row through a line diff of snapshot -> current lines; done if the text still matches.
--- 2. Otherwise search lines with the same text: the best surrounding context wins, then the closest row.
--- 3. Otherwise fuzzy-match text+context near the expected row.
--- 4. Otherwise nil: the caller keeps it as an orphan instead of dropping it.

local M = {}

M.CONTEXT = 2  -- lines kept above and below
M.FUZZY_WINDOW = 50  -- fuzzy search only within this many rows of the expected row
M.FUZZY_THRESHOLD = 0.8
local MAX_COMPARE_LEN = 120  -- cap line length for fuzzy comparison, levenshtein is O(n*m)

local function norm(s)
    return vim.trim(s or '')
end

--- Build an anchor for a row
---
--- @param lines string[] # whole file
--- @param row integer # 1-indexed
--- @return table # {row, line, before={...}, after={...}}
function M.make(lines, row)
    local before, after = {}, {}
    for i = math.max(1, row - M.CONTEXT), row - 1 do table.insert(before, lines[i]) end
    for i = row + 1, math.min(#lines, row + M.CONTEXT) do table.insert(after, lines[i]) end
    return { row = row, line = lines[row] or '', before = before, after = after }
end

--- Line diff between two versions of a file, computed once per file and reused for every anchor
---
--- @return table[] # hunks {start_a, count_a, start_b, count_b}
function M.diff(old_lines, new_lines)
    local old_text = table.concat(old_lines, '\n') .. '\n'
    local new_text = table.concat(new_lines, '\n') .. '\n'
    return vim.diff(old_text, new_text, { result_type = 'indices', algorithm = 'histogram' })
end

--- Map an old row to the new file through diff hunks
---
--- @return integer|nil, integer # new row (nil if the row itself was changed), expected row to search around
function M.map_row(hunks, row)
    local offset = 0
    for _, hunk in ipairs(hunks) do
        local start_a, count_a, start_b, count_b = unpack(hunk)
        if count_a == 0 then
            if row <= start_a then break end  -- pure insertion below start_a
        else
            if row < start_a then break end
            if row < start_a + count_a then
                return nil, start_b + math.min(row - start_a, math.max(count_b - 1, 0))
            end
        end
        offset = offset + count_b - count_a
    end
    return row + offset, row + offset
end

--- Similarity of two strings by Levenshtein distance
--- e.g., 'haha' & 'haha' -> 1; 'haha'&'hiha' -> 0.75; 'haha'&'lol'->0
---
--- @reference https://en.wikipedia.org/wiki/Levenshtein_distance
--- @return number # 0-1. 1 - identical; 0 - completely different
function M.similarity(str1, str2)
    if str1 == str2 then return 1 end
    str1, str2 = str1:sub(1, MAX_COMPARE_LEN), str2:sub(1, MAX_COMPARE_LEN)
    if #str1 == 0 or #str2 == 0 then return 0 end
    local a, b = { str1:byte(1, -1) }, { str2:byte(1, -1) }
    local v0 = {}
    for j = 0, #b do v0[j] = j end
    for i = 1, #a do
        local v1 = { [0] = i }
        for j = 1, #b do
            local cost = (a[i] == b[j]) and 0 or 1
            v1[j] = math.min(v1[j - 1] + 1, v0[j] + 1, v0[j - 1] + cost)
        end
        v0 = v1
    end
    return 1 - (v0[#b] / math.max(#a, #b))
end

local function line_score(saved, current, fuzzy)
    if current == nil then return 0 end
    saved, current = norm(saved), norm(current)
    if saved == current then return 1 end
    if not fuzzy then return 0 end
    return M.similarity(saved, current)
end

--- @return number # 0-1, how well the lines around `row` match the anchor's before/after lines
local function context_score(anchor, lines, row, fuzzy)
    local total, score = 0, 0
    for k, text in ipairs(anchor.before) do
        total = total + 1
        score = score + line_score(text, lines[row - (#anchor.before - k + 1)], fuzzy)
    end
    for k, text in ipairs(anchor.after) do
        total = total + 1
        score = score + line_score(text, lines[row + k], fuzzy)
    end
    if total == 0 then return 0 end
    return score / total
end

--- Find the anchor's row in the current lines
---
--- @param anchor table # from M.make()
--- @param lines string[] # current file
--- @param hunks table[]|nil # M.diff(snapshot, lines); nil when there's no trusted snapshot
--- @return integer|nil # row, or nil when nothing matches confidently
function M.locate(anchor, lines, hunks)
    local target = norm(anchor.line)
    local expected = anchor.row
    if hunks then
        local row
        row, expected = M.map_row(hunks, anchor.row)
        if row and lines[row] and norm(lines[row]) == target then return row end
    end
    -- Same text: best context, then the closest to the expected row
    local best, best_score, best_dist = nil, -1, math.huge
    for row, text in ipairs(lines) do
        if norm(text) == target then
            local score = context_score(anchor, lines, row, false)
            local dist = math.abs(row - expected)
            if score > best_score or (score == best_score and dist < best_dist) then
                best, best_score, best_dist = row, score, dist
            end
        end
    end
    -- A blank line on its own says nothing, it needs its context to match too
    if best and (target ~= '' or best_score >= 0.5) then return best end
    if target == '' then return nil end
    -- Edited line: fuzzy text + context, near the expected row only
    best, best_score = nil, M.FUZZY_THRESHOLD
    for row = math.max(1, expected - M.FUZZY_WINDOW), math.min(#lines, expected + M.FUZZY_WINDOW) do
        local score = 0.6 * line_score(target, lines[row], true) + 0.4 * context_score(anchor, lines, row, true)
        if score > best_score then
            best, best_score = row, score
        end
    end
    return best
end


--- Tests: `nvim -l tests/run.lua`, fixtures under tests/fixtures/
local function read_fixture(name)
    local dir = vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2)) .. '/../../tests/fixtures/'
    return vim.fn.readfile(dir .. name)
end

local function eq(actual, expected, msg)
    assert(actual == expected, string.format('%s: expected %s, got %s', msg, vim.inspect(expected), vim.inspect(actual)))
end

function M.test_similarity()
    eq(M.similarity('haha', 'haha'), 1, 'identical')
    eq(M.similarity('haha', 'hiha'), 0.75, 'one char changed')
    eq(M.similarity('haha', 'lolo'), 0, 'different')
    eq(M.similarity('', 'abc'), 0, 'empty')
end

function M.test_map_row_through_diff()
    local old, new = read_fixture('v1.lua'), read_fixture('v2.lua')
    local hunks = M.diff(old, new)
    -- `local function save(data)` is line 8 in v1 and line 11 in v2 (3 lines inserted above)
    eq(M.map_row(hunks, 8), 11, 'shifted by insertion')
    eq(M.map_row(hunks, 1), 1, 'above any change')
end

function M.test_locate_with_snapshot()
    local old, new = read_fixture('v1.lua'), read_fixture('v2.lua')
    local hunks = M.diff(old, new)
    eq(M.locate(M.make(old, 8), new, hunks), 11, 'unchanged line follows the diff')
    -- `return nil` appears twice in each version, context picks the right one
    eq(M.locate(M.make(old, 16), new, hunks), 19, 'duplicate text resolved by context')
end

function M.test_locate_without_snapshot()
    local old, new = read_fixture('v1.lua'), read_fixture('v2.lua')
    eq(M.locate(M.make(old, 8), new, nil), 11, 'found by exact text')
    -- `print('saving', path)` became `print('saving file', path)` in v2
    eq(M.locate(M.make(old, 10), new, nil), 13, 'edited line found by fuzzy match')
    eq(M.locate(M.make(old, 20), new, nil), 23, 'duplicate text resolved by context')
end

function M.test_locate_orphan()
    local old, new = read_fixture('v1.lua'), read_fixture('v2.lua')
    -- `local DEBUG = os.getenv('DEBUG')` was deleted in v2
    eq(M.locate(M.make(old, 3), new, M.diff(old, new)), nil, 'deleted line is an orphan')
end

return M
