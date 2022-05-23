-- Lua wrappers for the notmuch cli

local json = require "justabit.json"
local posix_spawn = require "spawn.posix"
local waitpid = require "spawn.wait".waitpid
local unix = require "unix"

local notmuch_methods = {}
local notmuch_mt = {
	__name = "notmuch cli";
	__index = notmuch_methods;
}

local function new(config_file)
	return setmetatable({
		config_file = config_file;
	}, notmuch_mt)
end

local function run_command(args)
	local pipe, pid do
		local file_actions = assert(posix_spawn.new_file_actions())

		-- child gets /dev/null as stdin
		file_actions:addopen(0, "/dev/null", {rdonly = true})

		-- child gets same pipe as both stdout and stderr
		local child_output
		pipe, child_output = assert(unix.fpipe("e"))
		assert(file_actions:adddup2(unix.fileno(child_output), 1))
		-- assert(file_actions:adddup2(1, 2))

		pid = assert(posix_spawn.spawnp(args[1], file_actions, nil, args, nil))
		-- close file now owned by the child
		child_output:close()
	end

	local output = pipe:read("*a")
	pipe:close()
	local ok, status, errno = waitpid(pid)
	if ok then -- zero status code
		return output
	elseif status == "exit" then -- syscall didn't fail; child program just had non-zero exit
		return nil, output, errno
	else
		return nil, status, errno
	end
end

local function trim_trailing_newline(str)
	assert(str:sub(-1, -1) == "\n", "expected trailing newline")
	return str:sub(1, -2)
end

-- Quote a term for a notmuch query
local function quote(s)
	if s:match("^[%w@-]+$") then
		return s
	end
	return '"' .. s:gsub('"', '""') .. '"'
end

local function get_body_preview(body_parts)
	for _, v in ipairs(body_parts) do
		local content_type = v["content-type"]
		if content_type == "text/plain" then
			return v.content:sub(1, 256)
		elseif content_type == "multipart/alternative" then
			local child = get_body_preview(v.content)
			if child then
				return child
			end
		end
	end
	return nil
end

-- From notmuch tag to IMAP role
-- Values are from https://www.iana.org/assignments/imap-mailbox-name-attributes/imap-mailbox-name-attributes.xhtml
-- Must be lowercased
local tag_to_role = {
	inbox = "inbox";
	draft = "drafts";
	flagged = "flagged";
	-- sent = "sent";
}

function notmuch_methods:run_notmuch(...)
	local args = table.pack(...)
	local actual_args = {"notmuch"}
	local offset = 1
	if self.config_file then
		offset = offset + 1
		actual_args[offset] = "--config="..self.config_file
	end
	for i=1, args.n do
		actual_args[i+offset] = args[i]
	end
	print("RUNNING", table.unpack(actual_args))
	return assert(run_command(actual_args))
end

function notmuch_methods:config_get(field)
	local value = self:run_notmuch("config", "get", field)
	return trim_trailing_newline(value)
end

function notmuch_methods:count(search)
	local output = self:run_notmuch("count", search)
	return tonumber(trim_trailing_newline(output), 10)
end

function notmuch_methods:count_threads(search)
	local output = self:run_notmuch("count", "--output=threads", search)
	return tonumber(trim_trailing_newline(output), 10)
end

-- Returns count, uuid, lastmod_str
function notmuch_methods:read_database_lastmod(search)
	local output = self:run_notmuch("count", "--lastmod", search)
	local count, uuid, lastmod_str = output:match("^(%d+)\t(%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x)\t(%d+)\n")
	return tonumber(count, 10), uuid, lastmod_str
end

-- Has a prefix to avoid ever starting with a number
-- Uses a separator in the valid Id charset https://jmap.io/spec-core.html#the-id-data-type
function notmuch_methods:state_value(search)
	local _, uuid, lastmod_str = self:read_database_lastmod(search)
	return string.format("S%s_%x", uuid, lastmod_str)
end

local function parse_state_value(state_value)
	local uuid, lastmod_str = state_value:match("^S(%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x)_(%x+)$")
	if not uuid then
		return nil, "invalid state value"
	end
	return uuid, lastmod_str
end

function notmuch_methods:search(search, sort, offset, limit, since_state_value)
	if sort then
		sort = "--sort=" .. sort
	else
		sort = ""
	end
	if offset then
		-- note: can be negative
		offset = string.format("--offset=%d", offset)
	else
		offset = ""
	end
	if limit then
		limit = string.format("--limit=%d", limit)
	else
		limit = ""
	end
	local uuid
	if since_state_value then
		local lastmod_str
		uuid, lastmod_str = parse_state_value(since_state_value)
		if not uuid then
			return uuid, lastmod_str
		end
		uuid = "--uuid=" .. uuid
		search = search .. " lastmod:" .. lastmod_str
	else
		uuid = ""
	end
	local output = self:run_notmuch("search", "--output=messages", "--format=json", sort, offset, limit, uuid, search)
	return json.decode(output)
end

-- function notmuch_methods:show(search, sort, offset, limit)
-- 	if sort then
-- 		sort = "--sort=" .. sort
-- 	end
-- 	if offset then
-- 		-- note: can be negative
-- 		offset = string.format("--offset=%d", offset)
-- 	end
-- 	if limit then
-- 		limit = string.format("--limit=%d", limit)
-- 	end
-- 	local output = self:run_notmuch("show", "--output=messages", "--format=json", "--entire-thread=false", sort, offset, limit, search)
-- 	return json.decode(output)
-- end

function notmuch_methods:get_thread_ids(search)
	local output = self:run_notmuch("search", "--output=threads", "--format=json", search)
	return json.decode(output)
end

function notmuch_methods:get_tags(search)
	local output = self:run_notmuch("search", "--output=tags", "--format=json", search)
	return json.decode(output)
end

function notmuch_methods:get_raw_mail(search)
	return self:run_notmuch("show", "--format=raw", search)
end

return {
	new = new;
	tag_to_role = tag_to_role;
	get_body_preview = get_body_preview;
	parse_state_value = parse_state_value;
	quote = quote;
}
