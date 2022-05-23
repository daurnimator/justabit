-- Each of these functions modifies the `res_headers` argument and (optionally) returns a string for the body

local json = require "justabit.json"

local function basic_error(res_headers, code)
	res_headers:upsert(":status", code)
	-- res_headers:append("content-type", "text/plain")
	-- return "Not Found"
end

local function RFC7807_error(res_headers, args)
	local status = string.format("%d", args.status)
	res_headers:upsert(":status", status)
	res_headers:append("content-type", "application/problem+json")
	return json.encode(args)
end

local function e400(res_headers)
	return basic_error(res_headers, "400")
end

local function e404(res_headers)
	return basic_error(res_headers, "404")
end

local function e405(res_headers)
	return basic_error(res_headers, "405")
end

local function unknownCapability(res_headers, detail)
	return RFC7807_error(res_headers, {
		type = "urn:ietf:params:jmap:error:unknownCapability";
		status = 400;
		detail = detail;
	})
end

local function notJSON(res_headers, detail)
	return RFC7807_error(res_headers, {
		type = "urn:ietf:params:jmap:error:notJSON";
		status = 400;
		detail = detail;
	})
end

local function notRequest(res_headers, detail)
	return RFC7807_error(res_headers, {
		type = "urn:ietf:params:jmap:error:notRequest";
		status = 400;
		detail = detail;
	})
end

local function limit(res_headers, detail)
	return RFC7807_error(res_headers, {
		type = "urn:ietf:params:jmap:error:limit";
		status = 400;
		detail = detail;
	})
end

return {
	basic_error = basic_error;
	RFC7807_error = RFC7807_error;
	e400 = e400;
	e404 = e404;
	e405 = e405;
	unknownCapability = unknownCapability;
	notJSON = notJSON;
	notRequest = notRequest;
	limit = limit;
}
