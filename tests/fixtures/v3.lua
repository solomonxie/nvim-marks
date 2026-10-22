-- Storage helpers
-- (v3: payload writer renamed)
local M = {}

local function encode(data)
    return vim.json.encode(data)
end

local function write_payload(payload, opts)
    local path = M.path()
    print('saving', path)
    return encode(payload)
end

function M.load(path)
    if not path then
        return nil
    end
    local f = io.open(path)
    if not f then
        return nil
    end
    return f:read('*a')
end

return M
