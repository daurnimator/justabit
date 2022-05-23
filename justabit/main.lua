#!/usr/bin/env lua
--[[
Usage: lua justabit/main.lua [<port>]
]]

local port = arg[1] or 0 -- 0 means pick one at random

local http_server = require "http.server"
local http_headers = require "http.headers"
local http_patterns = require "lpeg_patterns.http"
local basexx = require "basexx"

local justabit_api = require "justabit.api"
local json = require "justabit.json"
local notmuch = require "justabit.notmuch"
local response_helpers = require "justabit.response_helpers"

local TIMEOUT = 2

local escape_id = basexx.to_url64
-- local unescape_id = basexx.from_url64

local server_capabilities = {
    ["urn:ietf:params:jmap:core"] = {
		maxSizeUpload = 50000000;
		maxConcurrentUpload = 8;
		maxSizeRequest = 10000000;
		maxConcurrentRequests = 8;
		maxCallsInRequest = 32;
		maxObjectsInGet = 256;
		maxObjectsInSet = 128;
		collationAlgorithms = {
			"i;ascii-numeric";
			"i;ascii-casemap";
			"i;unicode-casemap"
		}
	};
	["urn:ietf:params:jmap:mail"] = {
		maxMailboxesPerEmail = json.null;
		maxMailboxDepth = 1;
		maxSizeMailboxName = 4096;
		maxSizeAttachmentsPerEmail = 550000000;
		emailQuerySortOptions = json.Array{};
		mayCreateTopLevelMailbox = true;
	};
	["urn:ietf:params:jmap:submission"] = {
		maxDelayedSend = 0;
		submissionExtensions = json.Array{};
	};
	-- ["urn:ietf:params:jmap:contacts"] = {};
}

local function get_session_body(base_url)
	local nm = notmuch.new()

	local body = {
		capabilities = server_capabilities;
		accounts = {};
		primaryAccounts = {};
		username = "";
		apiUrl = base_url .. "/api/";
		downloadUrl = base_url .. "/download/{accountId}/{blobId}/{name}?accept={type}";
		uploadUrl = base_url .. "/upload/{accountId}/";
		eventSourceUrl = base_url .. "/eventsource/?types={types}&closeafter={closeafter}&ping={ping}";
		state = nm:state_value("*");
	}

	-- body.accounts["A13824"] = {
	-- 	name = "john@example.com";
	-- 	isPersonal = true;
	-- 	isReadOnly = false;
	-- 	accountCapabilities = {
	-- 		["urn:ietf:params:jmap:mail"] = {
	-- 			maxMailboxesPerEmail = json.null;
	-- 			maxMailboxDepth = 10;
	-- 			-- maxSizeMailboxName
	-- 			-- maxSizeAttachmentsPerEmail
	-- 			-- emailQuerySortOptions
	-- 			-- mayCreateTopLevelMailbox
	-- 		};
	-- 		-- ["urn:ietf:params:jmap:contacts"] = {}
	-- 	};
	-- }
	-- body.primaryAccounts["urn:ietf:params:jmap:mail"] = "A13824"
	-- -- body.primaryAccounts["urn:ietf:params:jmap:contacts"] = "A13824"

	-- body.accounts["A97813"] = {
	-- 	name = "jane@example.com";
	-- 	isPersonal = false;
	-- 	isReadOnly = true;
	-- 	accountCapabilities = {
	-- 		["urn:ietf:params:jmap:mail"] = {
	-- 		  maxMailboxesPerEmail = 1;
	-- 		  maxMailboxDepth = 10;
	-- 		}
	-- 	},
	-- }

	local primary_email = nm:config_get("user.primary_email")
	local primary_account_id = escape_id(primary_email)
	body.accounts[primary_account_id] = {
		name = primary_email;
		isPersonal = true;
		isReadOnly = false;
		accountCapabilities = {
			["urn:ietf:params:jmap:mail"] = {
				maxMailboxesPerEmail = json.null;
				-- maxMailboxDepth = 10;
				-- maxSizeMailboxName
				-- maxSizeAttachmentsPerEmail
				-- emailQuerySortOptions
				-- mayCreateTopLevelMailbox
			};
			-- ["urn:ietf:params:jmap:contacts"] = {}
		};
	}
	body.primaryAccounts["urn:ietf:params:jmap:mail"] = primary_account_id
	-- local other_email = nm:config_get("user.other_email")
	-- for email in other_email:gmatch("[^;]+") do

	-- end

	return body
end


local function get_content_type(req_headers)
	local header_value = req_headers:get "content-type"
	if header_value == nil then
		return nil, "missing content-type header"
	end
	local header_split = http_patterns.Content_Type:match(header_value)
	if not header_split then
		return nil, "unable to parse content-type header"
	end
	return header_split
end

-- Returns body
local function handle_request(req_headers, stream, res_headers)
	local method = req_headers:get ":method"
	if method == "OPTIONS" then
		res_headers:upsert(":status", "204")
		return
	end
	if method == "HEAD" then
		method = "GET"
	end

	local path = req_headers:get ":path"
	if path == "/.well-known/jmap" then
		res_headers:upsert(":status", "200")
		res_headers:append("content-type", "application/json")
		res_headers:append("cache-control", "no-cache, no-store, must-revalidate")
		local base_url = req_headers:get ":scheme" .. "://" .. req_headers:get ":authority"
		return json.encode(get_session_body(base_url))
	elseif path:match "^/eventsource/" then
		error"TODO"
	elseif path:match "^/api/" then
		if method ~= "POST" then return response_helpers.e405(res_headers) end

		local ct, ct_err = get_content_type(req_headers)
		if not (ct.type == "application" and ct.subtype == "json") then
			return response_helpers.notJSON(res_headers, ct_err)
		end

		local unparsed_req_body = assert(stream:get_body_as_string(TIMEOUT))
		local req_body, err = json.decode(unparsed_req_body)
		if not req_body then
			return response_helpers.notJSON(res_headers, err)
		end

		res_headers:upsert(":status", "200")
		res_headers:append("content-type", "application/json")
		return justabit_api.get_response(server_capabilities, req_body, res_headers)
	else
		return response_helpers.e404(res_headers)
	end
end

local function reply(myserver, stream) -- luacheck: ignore 212
	-- Read in headers
	local req_headers = assert(stream:get_headers())
	local req_method = req_headers:get ":method"
	local path = req_headers:get ":path"

	-- Log request to stdout
	assert(io.stdout:write(string.format('[%s] "%s %s HTTP/%g"  "%s" "%s"\n',
		os.date("%d/%b/%Y:%H:%M:%S %z"),
		req_method or "",
		path or "",
		stream.connection.version,
		req_headers:get("referer") or "-",
		req_headers:get("user-agent") or "-"
	)))

	local res_headers = http_headers.new()
	res_headers:append(":status", "500")
	res_headers:append("access-control-allow-headers", "Content-Type,Authorization,Range,Content-Encoding,X-ME-ConnectionId,Cache-Control,Last-Event-ID")
	res_headers:append("access-control-allow-methods", "GET, POST, OPTIONS")
	res_headers:append("access-control-allow-origin", "*")
	res_headers:append("access-control-max-age", "3600")

	local ok, body = xpcall(handle_request, debug.traceback, req_headers, stream, res_headers)
	if not ok then
		error(body)
	end

	if res_headers:get(":status") ~= "200" then
		print("RESPONSE WAS NOT OK. body:", body)
	end

	-- Send headers to client; end the stream immediately if this was a HEAD request
	local has_no_body = body == nil or req_method == "HEAD"
	assert(stream:write_headers(res_headers, has_no_body))
	if not has_no_body then
		-- Send body, ending the stream
		assert(stream:write_chunk(body, true))
	end
end

local myserver = assert(http_server.listen {
	host = "localhost";
	port = port;
	onstream = reply;
	onerror = function(myserver, context, op, err, errno) -- luacheck: ignore 212
		local msg = op .. " on " .. tostring(context) .. " failed"
		if err then
			msg = msg .. ": " .. tostring(err)
		end
		assert(io.stderr:write(msg, "\n"))
	end;
})

-- Manually call :listen() so that we are bound before calling :localname()
assert(myserver:listen())
do
	local bound_port = select(3, myserver:localname())
	assert(io.stderr:write(string.format("Now listening on port %d\n", bound_port)))
end
-- Start the main server loop
assert(myserver:loop())
