-- JSON routines we need

-- local json = require "dkjson"
local json = require "cjson"

-- local array_mt = {__jsontype = "array"}
local array_mt = json.array_mt
local Array = function(t)
	return setmetatable(t, array_mt)
end

local null = json.null

-- local function decode(s)
-- 	return json.decode(s, 1, json.null, nil, array_mt)
-- end
json.decode_array_with_array_mt(true)
local decode = json.decode

return {
	Array = Array;
	array_mt = array_mt;
	decode = decode;
	encode = json.encode;
	null = null;
}
