local M = {}

local DEBUG = os.getenv('DEBUG')

local function encode(data)
    return vim.json.encode(data)
end
local function save(data)
    local path = M.path()
    print('saving', path)
    return encode(data)
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
