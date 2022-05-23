local json = require "justabit.json"
local methods = require "justabit.methods"
local notmuch = require "justabit.notmuch"
local response_helpers = require "justabit.response_helpers"

-- Parse `path` as RFC6901 with special `*` treatment
local function lookup(path, ref)
	for reference_token, pos in path:gmatch("/([^/]*)()") do
		if getmetatable(ref) == json.array_mt then
			if reference_token == "*" then
				local new_path = path:sub(pos)
				local list = json.Array{}
				for _, v in ipairs(ref) do
					local tmp = lookup(new_path, v)
					-- If the result of applying the rest of the pointer tokens to each item was itself an array,
					-- the contents of this array are added to the output rather than the array itself
					-- (i.e., the result is flattened from an array of arrays to a single array).
					if getmetatable(tmp) == json.array_mt then
						for _, vv in ipairs(tmp) do
							table.insert(list, vv)
						end
					else
						table.insert(list, tmp)
					end
				end
				return list
			else
				if reference_token ~= "0" and not reference_token:match("^[1-9][0-9]*$") then
					return nil -- invalidResultReference
				end
				-- Add one to convert to 1-based indexing for Lua
				reference_token = tonumber(reference_token, 10) + 1
				ref = ref[reference_token]
			end
		else
			reference_token = reference_token:gsub("~([01])", {["0"]="~", ["1"]="/"})
			ref = ref[reference_token]
		end
	end
	return ref
end

-- https://jmap.io/spec-core.html#references-to-previous-method-results
local function process_result_refereces(args, methodResponses)
	local new_args = {}
	for k, ResultReference in pairs(args) do
		if k:sub(1, 1) == "#" then
			-- is a reference
			local arg_name = k:sub(2)
			if args[arg_name] ~= nil then
				return nil, { type = "invalidArguments" }
			end

			local resultOf = ResultReference.resultOf
			local name = ResultReference.name
			local path = ResultReference.path
			if type(resultOf) ~= "string" or type(name) ~= "string" or type(path) ~= "string" then
				return nil, { type = "invalidResultReference" }
			end

			local found_ref_target = nil
			for _, v in ipairs(methodResponses) do
				if v[3] == resultOf then
					found_ref_target = v
				end
			end
			if found_ref_target == nil then
				return nil, { type = "invalidResultReference" };
			end
			-- If the response name is not identical to the name property of the ResultReference, evaluation fails.
			if found_ref_target[1] ~= name then
				return nil, { type = "invalidResultReference" }
			end

			local ref = lookup(path, found_ref_target[2])
			if ref == nil then
				return nil, { type = "invalidResultReference" }
			end
			new_args[arg_name] = ref
		end
	end
	for k, v in pairs(new_args) do
		args["#"..k] = nil
		args[k] = v
	end
	return true
end

-- On sucess returns object
-- On failure returns `nil`, object where object conforms to RFC7807
local function get_response(server_capabilities, req, res_headers)
	if type(req.using) ~= "table" then
		return response_helpers.notRequest(res_headers, "Request object is invalid (missing `using` field)")
	end
	for _, v in ipairs(req.using) do
		if server_capabilities[v] == nil then
			return response_helpers.unknownCapability(res_headers, string.format("The Request object used capability %q, which is not supported by this server.", v))
		end
	end

	local nm = notmuch.new()

	local res = {
		methodResponses = {};
		createdIds = nil;
		sessionState = nil;
	}

	if req.createdIds then
		res.createdIds = {}
		error("NYI")
	end

	for _, invocation in ipairs(req.methodCalls) do
		local name = invocation[1]
		local args = invocation[2]
		local id = invocation[3]
		if type(name) ~= "string" or type(args) ~= "table" or type(id) ~= "string" then
			return response_helpers.notRequest(res_headers, "Request object is invalid (invalid methodCall)")
		end
		do
			local ok, err = process_result_refereces(args, res.methodResponses)
			if not ok then
				table.insert(res.methodResponses, {"error", err, id})
				goto nextMethodCall
			end
		end
		local method = methods[name]
		if method == nil then
			print("Unknown method: "..name)
			table.insert(res.methodResponses, {
				"error",
				{ type = "unknownMethod" },
				id,
			})
			goto nextMethodCall
		end

		local methodResults, err = method(nm, args)
		if methodResults == nil then
			table.insert(res.methodResponses, {"error", err, id})
			goto nextMethodCall
		end
		for _, v in pairs(methodResults) do
			table.insert(res.methodResponses, {name, v, id})
		end

		:: nextMethodCall ::
	end

	res.sessionState = nm:state_value("*");

	return json.encode(res)
end

return {
	get_response = get_response;
}
