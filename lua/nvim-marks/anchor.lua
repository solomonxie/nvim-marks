--- Find where a saved line is now, after the file changed (edits, branch switch, worktree, rebase).
---
--- Each mark/note keeps an anchor: its row, the line's text, and short hashes of the 2 lines above and below.
--- On restore:
--- 1. The saved row still has the same text, and the lines around it still match: done.
--- 2. Otherwise search lines with the same text: the best matching surroundings win, then the closest row.
--- 3. Otherwise fuzzy-match the text (surroundings must match too) near the saved row.
--- 4. Otherwise nil: the caller keeps it as an orphan instead of dropping it.

local M = {}

M.CONTEXT = 2  -- lines hashed above and below
M.FUZZY_WINDOW = 50  -- fuzzy search only within this many rows of the saved row
M.FUZZY_THRESHOLD = 0.8
local MAX_COMPARE_LEN = 120  -- cap line length for fuzzy comparison, levenshtein is O(n*m)
local HASH_LEN = 8
M.HASH_LEN = HASH_LEN

local function norm(s)
    return vim.trim(s or '')
end

--- @return string # short hash of a line, ignoring indentation
function M.hash(line)
    return vim.fn.sha256(norm(line)):sub(1, HASH_LEN)
end

--- Build an anchor for a row
---
--- @param lines string[] # whole file
--- @param row integer # 1-indexed
--- @return table # {row, line, above={hash...}, below={hash...}}
function M.make(lines, row)
    local above, below = {}, {}
    for i = math.max(1, row - M.CONTEXT), row - 1 do table.insert(above, M.hash(lines[i])) end
    for i = row + 1, math.min(#lines, row + M.CONTEXT) do table.insert(below, M.hash(lines[i])) end
    return { row = row, line = lines[row] or '', above = above, below = below }
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

--- @return number # 0-1, share of the anchor's above/below hashes that match the lines around `row`
local function context_score(anchor, lines, row, hashes)
    local function hash_at(i)
        if lines[i] == nil then return nil end
        hashes[i] = hashes[i] or M.hash(lines[i])
        return hashes[i]
    end
    local total, score = 0, 0
    for k, h in ipairs(anchor.above or {}) do
        total = total + 1
        if hash_at(row - (#anchor.above - k + 1)) == h then score = score + 1 end
    end
    for k, h in ipairs(anchor.below or {}) do
        total = total + 1
        if hash_at(row + k) == h then score = score + 1 end
    end
    if total == 0 then return 0 end
    return score / total
end

--- Find the anchor's row in the current lines
---
--- @param anchor table # from M.make()
--- @param lines string[] # current file
--- @param hashes table|nil # cache of line hashes, pass the same table for every anchor of one file
--- @return integer|nil # row, or nil when nothing matches confidently
function M.locate(anchor, lines, hashes)
    hashes = hashes or {}
    local target = norm(anchor.line)
    local expected = anchor.row
    -- Same text at the saved row and all its surroundings match: done. Otherwise the same line may also exist
    -- elsewhere (e.g. a copied block after a `git pull`), so the search below picks the best fit; the saved row
    -- is one of the candidates and wins ties
    local has_context = #(anchor.above or {}) + #(anchor.below or {}) > 0
    if lines[expected] and norm(lines[expected]) == target and target ~= ''
        and (not has_context or context_score(anchor, lines, expected, hashes) == 1) then
        return expected
    end
    -- Same text: best context, then the closest to the saved row
    local best, best_score, best_dist = nil, -1, math.huge
    for row, text in ipairs(lines) do
        if norm(text) == target then
            local score = context_score(anchor, lines, row, hashes)
            local dist = math.abs(row - expected)
            if score > best_score or (score == best_score and dist < best_dist) then
                best, best_score, best_dist = row, score, dist
            end
        end
    end
    -- A blank line on its own says nothing, it needs its context to match too
    if best and (target ~= '' or best_score >= 0.5) then return best end
    if target == '' then return nil end
    -- Edited line: fuzzy text + exact context, near the saved row only
    best, best_score = nil, M.FUZZY_THRESHOLD
    for row = math.max(1, expected - M.FUZZY_WINDOW), math.min(#lines, expected + M.FUZZY_WINDOW) do
        -- With no surrounding-line hashes (e.g. a hand-written tour step) only the text can be compared
        local score = has_context and (0.6 * M.similarity(target, norm(lines[row])) + 0.4 * context_score(anchor, lines, row, hashes))
                      or M.similarity(target, norm(lines[row]))
        if score > best_score then
            best, best_score = row, score
        end
    end
    return best
end

--- Carry a row of `old` over to `new` through their diff: shifted by the lines added or removed above it, and on
--- a changed line, to the line that replaced it
---
--- @return integer|nil # row in `new`, nil when its line was deleted
function M.map_row(old, new, row)
    local diff = vim.text.diff or vim.diff  -- vim.diff before nvim 0.12
    local hunks = diff(table.concat(old, '\n') .. '\n', table.concat(new, '\n') .. '\n', {result_type='indices'})
    local shift = 0
    for _, h in ipairs(hunks) do
        local old_start, old_count, new_start, new_count = unpack(h)
        if old_count == 0 then old_start = old_start + 1 end  -- pure insert: `old_start` is the line it goes after
        if new_count == 0 then new_start = new_start + 1 end
        if row < old_start then break end
        if row < old_start + old_count then
            if new_count == 0 then return nil end
            -- The hunk's new line most like it (a blank line added next to a rewritten one doesn't win)
            local best, best_score = new_start + math.min(row - old_start, new_count - 1), -1
            for r = new_start, new_start + new_count - 1 do
                local score = M.similarity(norm(old[row]), norm(new[r]))
                if score > best_score then best, best_score = r, score end
            end
            return best
        end
        shift = shift + new_count - old_count
    end
    return row + shift
end

--- Convert an anchor saved by v2 (`before`/`after` holding full lines) to hashes
function M.upgrade(anchor)
    if anchor.above == nil and (anchor.before or anchor.after) then
        anchor.above = vim.tbl_map(M.hash, anchor.before or {})
        anchor.below = vim.tbl_map(M.hash, anchor.after or {})
        anchor.before, anchor.after = nil, nil
    end
    return anchor
end

return M
