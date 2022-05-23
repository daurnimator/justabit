local basexx = require "basexx"
local json = require "justabit.json"
local mime = require "justabit.mime"
local notmuch = require "justabit.notmuch"

local escape_id = basexx.to_url64
local unescape_id = basexx.from_url64

-- https://jmap.io/spec-core.html#the-date-and-utcdate-data-types
local function UTCDate(timestamp)
	return os.date("!%Y-%m-%dT%H:%M:%SZ", timestamp)
end


local methods = {}

methods["Mailbox/get"] = function(nm, args)
	print("Mailbox/get", args.accountId, json.encode(args.ids), json.encode(args.properties))
	local primary_email = nm:config_get("user.primary_email")
	assert(args.accountId == escape_id(primary_email), "mismatched account id. TODO: other accounts?")
	local query
	if args.ids ~= json.null and args.ids ~= nil then -- nil seen from jmap-mua
		query = {}
		for i, v in ipairs(args.ids) do
			query[i] = "tag:" .. notmuch.quote(v)
		end
		query = table.concat(query, " ")
	elseif type(args.ids) ~= "table" then
		query = "*"
	else
		return nil, { type = "invalidArguments", detail = "invalid ids" }
	end
	if args.properties then
		error("TODO")
	end

	local exclude_tags = {}
	for tag in nm:config_get("search.exclude_tags"):gmatch("[^;]+") do
		exclude_tags[tag] = true
	end
	local list = json.Array{}
	for i, tag in ipairs(nm:get_tags(query)) do
		list[i] = {
			id = tag;
			name = tag;
			parentId = nil;
			role = notmuch.tag_to_role[tag];
			sortOrder = nil;
			totalEmails = nm:count("tag:"..notmuch.quote(tag));
			unreadEmails = nm:count("tag:"..notmuch.quote(tag).." and tag:unread");
			totalThreads = nm:count_threads("tag:"..notmuch.quote(tag));
			unreadThreads = nm:count_threads("tag:"..notmuch.quote(tag).." and tag:unread");
			myRights = {
				mayReadItems = true;
				mayAddItems = true;
				mayRemoveItems = true;
				maySetSeen = true;
				maySetKeywords = true;
				mayCreateChild = false;
				mayRename = false;
				mayDelete = false;
				maySubmit = false;
			};
			isSubscribed = exclude_tags[tag] ~= true;
		}
	end
	local res = {
		accountId = args.accountId;
		state = nm:state_value(query);
		list = list;
		notFound = json.Array{};
	}
	return {res}
end

local function array_to_set(t)
	local s = {}
	for _, v in ipairs(t) do
		s[v] = true
	end
	return s
end

local function last_header(headers_all, field)
	local a = headers_all[field]
	if a == nil then
		return nil
	end
	return a[#a]
end

local function each_message_in_thread_nodes(thread_nodes)
	for _, v in ipairs(thread_nodes) do
		do
			local message = v[1]
			if message ~= json.null then
				coroutine.yield(message)
			end
		end
		each_message_in_thread_nodes(v[2])
	end
end

local function each_message_in_threads(threads)
	return coroutine.wrap(function()
		for _, v in ipairs(threads) do
			each_message_in_thread_nodes(v)
		end
	end)
end

-- local email_known_properties = {}
local email_default_properties = {
	id = true;
	blobId = true;
	threadId = true;
	mailboxIds = true;
	keywords = true;
	size = true;

	receivedAt = true;
	messageId = true;
	inReplyTo = true;
	references = true;
	sender = true;
	from = true;

	to = true;
	cc = true;
	bcc = true;
	replyTo = true;
	subject = true;
	sentAt = true;
	hasAttachment = true;

	preview = true;
	bodyValues = true;
	textBody = true;
	htmlBody = true;
	attachments = true;
}
-- The email properties that are computed from raw
local email_property_needs_raw = {
	from = true;
	to = true;
	subject = true;
	size = true;
	headers = true;
}
methods["Email/get"] = function(nm, args)
	print("Email/get", args.accountId, json.encode(args.ids), json.encode(args.properties))
	local primary_email = nm:config_get("user.primary_email")
	assert(args.accountId == escape_id(primary_email), "mismatched account id. TODO: other accounts?")

	local ids
	if args.ids == json.null then
		ids = nm:search("*")
	elseif type(args.ids) == "table" then
		ids = json.Array{}
		for i, v in ipairs(args.ids) do
			ids[i] = unescape_id(v)
		end
	else
		return nil, { type = "invalidArguments", detail = "invalid ids" }
	end

	local need_raw = false
	local properties = args.properties
	local header_properties = {}
	if properties == json.null then
		properties = email_default_properties
		need_raw = true
	else
		local s = {}
		for _, v in ipairs(properties) do
			local header_field, suffix = v:match("^header:([\33-\57\59-\126]+)(.*)$")
			if header_field then
				local as, rest = suffix:match("^:as([\33-\57\59-\126]+)(.*)$")
				if as then
					suffix = rest
				end
				local all = suffix == ":all"
				if all then
					suffix = ""
				end
				if suffix ~= "" then
					return nil, { type = "invalidArguments", detail = "invalid header specification" }
				end

				local form_parser = mime.header_forms[as]
				if form_parser == nil then
					return nil, { type = "invalidArguments", detail = "unknown header-form" }
				end

				-- TODO: validate that the form is valid for the specific header

				need_raw = true
				header_properties[v] = {
					field = header_field:lower();
					form = form_parser;
					all = all;
				}
			else
				-- if not email_known_properties[v] then
				-- 	error("unknown property")
				-- end
				need_raw = need_raw or email_property_needs_raw[v]
				s[v] = true
			end
		end
		properties = s
	end
	local bodyProperties = args.bodyProperties
	if bodyProperties == nil then
		bodyProperties = {
			partId = true;
			blobId = true;
			size = true;
			name = true;
			type = true;
			charset = true;
			disposition = true;
			cid = true;
			language = true;
			location = true;
		}
	else
		if type(bodyProperties) ~= "table" then
			return nil, { type = "invalidArguments", detail = "invalid bodyProperties" }
		end
		bodyProperties = array_to_set(bodyProperties)
	end
	local fetchTextBodyValues = args.fetchTextBodyValues
	if fetchTextBodyValues ~= nil and type(fetchTextBodyValues) ~= "boolean" then
		return nil, { type = "invalidArguments", detail = "invalid fetchTextBodyValues" }
	end
	local fetchHTMLBodyValues = args.fetchHTMLBodyValues
	if fetchHTMLBodyValues ~= nil and type(fetchHTMLBodyValues) ~= "boolean" then
		return nil, { type = "invalidArguments", detail = "invalid fetchHTMLBodyValues" }
	end
	local fetchAllBodyValues = args.fetchAllBodyValues
	if fetchAllBodyValues ~= nil and type(fetchAllBodyValues) ~= "boolean" then
		return nil, { type = "invalidArguments", detail = "invalid fetchAllBodyValues" }
	end
	local maxBodyValueBytes = args.maxBodyValueBytes
	if maxBodyValueBytes ~= nil and type(maxBodyValueBytes) ~= "number" and maxBodyValueBytes%1 ~= 0 then
		return nil, { type = "invalidArguments", detail = "invalid maxBodyValueBytes" }
	end

	local list = json.Array{}
	local notFound = json.Array{}
	for _, id in ipairs(ids) do
		local id_query = "id:" .. notmuch.quote(id)

		local message do
			local output = nm:run_notmuch(
				"show", "--format=json", "--entire-thread=false",-- "--decrypt=false",
				fetchHTMLBodyValues and "--include-html" or "",
				id_query
			)
			local thread_set = json.decode(output)
			for m in each_message_in_threads(thread_set) do
				assert(message == nil, "this loop shouldn't iterate twice")
				message = m
			end
		end

		if message == nil then
			-- id doesn't exist/isn't known
			table.insert(notFound, escape_id(id))
			goto continue
		end

		local item = {
			id = escape_id(id);
		}

		local raw
		local headers_all
		local headers = json.Array{}
		if need_raw then
			raw = nm:get_raw_mail(id_query)
			headers_all = {}
			for _, s, e in mime.each_mime_header_line(raw) do
				local header = raw:sub(s, e)
				local name, value = header:match("[ \t]*([^:]+)[ \t]*:(.*)")
				assert(name, "invalid header")
				table.insert(headers, {name = name, value = value})

				local iname = name:lower() -- case insensitive
				local values = headers_all[iname]
				if values == nil then
					values = json.Array{value}
					headers_all[iname] = values
				else
					table.insert(values, value)
				end
			end
		end

		if properties.headers then
			item.headers = headers
		end

		if properties.blobId then
			item.blobId = item.id
		end
		if properties.threadId then
			-- It seems like the only way to get thread id is via a search
			item.threadId = "T" .. nm:get_thread_ids(id_query)[1]
		end
		if properties.mailboxIds then
			local mailboxIds = {}
			for _, v in ipairs(message.tags) do
				mailboxIds[v] = true
			end
			item.mailboxIds = mailboxIds
		end
		if properties.keywords then
			local keywords = {
				["$seen"] = true; -- is inverted 'unread' tag
			}
			for _, tag in pairs(message.tags) do
				-- See https://www.iana.org/assignments/imap-jmap-keywords/imap-jmap-keywords.xhtml
				if tag == "draft" then
					keywords["$draft"] = true
				elseif tag == "unread" then
					keywords["$seen"] = nil
				elseif tag == "flagged" then
					keywords["$flagged"] = true
				elseif tag == "replied" then
					keywords["$answered"] = true
				elseif tag == "spam" then
					keywords["$Junk"] = true
				elseif tag == "passed" then
					keywords["$Forwarded"] = true
				end
			end
			item.keywords = keywords
		end
		if properties.size then
			item.size = #raw
		end
		if properties.receivedAt then
			item.receivedAt = UTCDate(message.timestamp)
		end
		if properties.messageId then
			local h = last_header(headers_all, "message-id")
			if h then
				item.messageId = mime.header_forms.MessageIds(h)
			else
				item.messageId = json.null
			end
		end
		if properties.inReplyTo then
			local h = last_header(headers_all, "in-reply-to")
			if h then
				item.inReplyTo = mime.header_forms.MessageIds(h)
			else
				item.inReplyTo = json.null
			end
		end
		if properties.references then
			local h = last_header(headers_all, "references")
			if h then
				item.references = mime.header_forms.MessageIds(h)
			else
				item.references = json.null
			end
		end
		if properties.sender then
			local h = last_header(headers_all, "sender")
			if h then
				item.sender = mime.header_forms.Addresses(h)
			else
				item.sender = json.null
			end
		end
		if properties.from then
			local h = last_header(headers_all, "from")
			if h then
				item.from = mime.header_forms.Addresses(h)
			else
				item.from = json.null
			end
		end
		if properties.to then
			local h = last_header(headers_all, "to")
			if h then
				item.to = mime.header_forms.Addresses(h)
			else
				item.to = json.null
			end
		end
		if properties.cc then
			local h = last_header(headers_all, "cc")
			if h then
				item.cc = mime.header_forms.Addresses(h)
			else
				item.cc = json.null
			end
		end
		if properties.bcc then
			local h = last_header(headers_all, "bcc")
			if h then
				item.bcc = mime.header_forms.Addresses(h)
			else
				item.bcc = json.null
			end
		end
		if properties.replyTo then
			local h = last_header(headers_all, "reply-to")
			if h then
				item.replyTo = mime.header_forms.Addresses(h)
			else
				item.replyTo = json.null
			end
		end
		if properties.subject then
			local h = last_header(headers_all, "subject")
			if h then
				item.subject = mime.header_forms.Text(h)
			else
				item.subject = json.null
			end
		end
		if properties.sentAt then
			local h = last_header(headers_all, "date")
			if h then
				item.sentAt = mime.header_forms.Date(h)
			else
				item.sentAt = json.null
			end
		end
		if properties.hasAttachment then
			item.hasAttachment = message.body[2] ~= nil
		end
		if properties.preview then
			item.preview = notmuch.get_body_preview(message.body) or ""
		end
		if properties.bodyStructure then
			local p = {}
			error "NYI"
			-- if content_type == "multipart/*" then
			-- 	p.partId = json.null
			-- 	p.blobId = json.null
			-- 	p.subParts = json.Array{}
			-- else
			-- 	p.partId =
			-- 	p.blobId =
			-- 	p.subParts = json.null
			-- end
			-- p.size =
			-- p.headers = json.Array{}
			-- p.name = content_disposition.filename or content_type.name or json.null
			-- p.type = content_type or ("text/plain" or "message/rfc822") -- if inside a multipart/digest
			-- if content_type == nil or content_type == "text/*" then
			-- 	p.charset = content_type.charset or "us-ascii"
			-- else
			-- 	p.charset = json.null
			-- end
			-- p.disposition = content_disposition or json.null
			-- p.cid = content_id or json.null
			-- if content_language then
			-- 	p.language = json.Array{}
			-- else
			-- 	p.language = json.null
			-- end
			-- p.location = content_location or json.null
			item.bodyStructure = p
		end
		if properties.bodyValues then
			local v = {}
			error "NYI"
			-- v[partId] = {
			-- 	value =
			-- 	isEncodingProblem =
			-- 	isTruncated =
			-- }
			item.bodyValues = v
		end
		if properties.textBody then
			error "NYI"
			-- item.textBody =
		end
		if properties.htmlBody then
			error "NYI"
			-- item.htmlBody =
		end
		if properties.attachments then
			error "NYI"
			-- item.attachments =
		end

		for property_name, header_spec in pairs(header_properties) do
			local header_property
			if header_spec.all then
				header_property = json.Array{}
			else
				header_property = json.null
			end
			local header = headers_all[header_spec.field]
			if header then
				if header_spec.all then
					for i, v in ipairs(header) do
						header_property[i] = header_spec.form(v)
					end
				else
					local last_i = #header
					if last_i ~= 0 then
						local last = header[last_i]
						header_property = header_spec.form(last)
					end
				end
			end
			item[property_name] = header_property
		end

		table.insert(list, item)

		:: continue ::
	end

	local res = {
		accountId = args.accountId;
		state = nm:state_value("*");
		list = list;
		notFound = notFound;
	}
	return {res}
end

local function filter_to_query(filter)
	if filter.operator then
		-- is FilterOperator
		local operator = filter.operator
		local condition = filter.condition
		if operator == "AND" then
		elseif operator == "OR" then
		elseif operator == "NOT" then
		else
			return nil, { type = "invalidArguments", detail = "unknown FilterOperator" }
		end
		error "NYI"
	else -- is FilterCondition
		local query_t = {}
		if filter.inMailbox ~= nil then
			-- Id A Mailbox id. An Email must be in this Mailbox to match the condition.
			table.insert(query_t, "tag:" .. notmuch.quote(filter.inMailbox))
		end
		if filter.inMailboxOtherThan ~= nil then
			-- Id[] A list of Mailbox ids. An Email must be in at least one Mailbox not in this list to match the condition.
			-- This is to allow messages solely in trash/spam to be easily excluded from a search.
			error "NYI"
		end
		if filter.before ~= nil then
			-- UTCDate The receivedAt date-time of the Email must be before this date-time to match the condition.
			error "NYI"
		end
		if filter.after ~= nil then
			-- UTCDate The receivedAt date-time of the Email must be the same or after this date-time to match the condition.
			error "NYI"
		end
		if filter.minSize ~= nil then
			-- UnsignedInt The size property of the Email must be equal to or greater than this number to match the condition.
			error "NYI"
		end
		if filter.maxSize ~= nil then
			-- UnsignedInt The size property of the Email must be less than this number to match the condition.
			error "NYI"
		end
		if filter.allInThreadHaveKeyword ~= nil then
			-- String All Emails (including this one) in the same Thread as this Email must have the given keyword to match the condition.
			error "NYI"
		end
		if filter.someInThreadHaveKeyword ~= nil then
			-- String At least one Email (possibly this one) in the same Thread as this Email must have the given keyword to match the condition.
			error "NYI"
		end
		if filter.noneInThreadHaveKeyword ~= nil then
			-- String All Emails (including this one) in the same Thread as this Email must not have the given keyword to match the condition.
			error "NYI"
		end
		if filter.hasKeyword ~= nil then
			-- String This Email must have the given keyword to match the condition.
			error "NYI"
		end
		if filter.notKeyword ~= nil then
			-- String This Email must not have the given keyword to match the condition.
			error "NYI"
		end
		if filter.hasAttachment ~= nil then
			-- Boolean The hasAttachment property of the Email must be identical to the value given to match the condition.
			error "NYI"
		end
		if filter.text ~= nil then
			-- String Looks for the text in Emails. The server MUST look up text in the From, To, Cc, Bcc, and Subject header fields of the message and SHOULD look inside any text/* or other body parts that may be converted to text by the server. The server MAY extend the search to any additional textual property.
			error "NYI"
		end
		if filter.from ~= nil then
			-- String Looks for the text in the From header field of the message.
			error "NYI"
		end
		if filter.to ~= nil then
			-- String Looks for the text in the To header field of the message.
			error "NYI"
		end
		if filter.cc ~= nil then
			-- String Looks for the text in the Cc header field of the message.
			error "NYI"
		end
		if filter.bcc ~= nil then
			-- String Looks for the text in the Bcc header field of the message.
			error "NYI"
		end
		if filter.subject ~= nil then
			-- String Looks for the text in the Subject header field of the message.
			error "NYI"
		end
		if filter.body ~= nil then
			-- String Looks for the text in one of the body parts of the message. The server MAY exclude MIME body parts with content media types other than text/* and message/* from consideration in search matching. Care should be taken to match based on the text content actually presented to an end user by viewers for that media type or otherwise identified as appropriate for search indexing. Matching document metadata uninteresting to an end user (e.g., markup tag and attribute names) is undesirable.
			error "NYI"
		end
		if filter.header ~= nil then
			-- String[] The array MUST contain either one or two elements.
			-- The first element is the name of the header field to match against.
			-- The second (optional) element is the text to look for in the header field value.
			-- If not supplied, the message matches simply if it has a header field of the given name.
			error "NYI"
		end
		return table.concat(query_t, " ")
	end
end

methods["Email/query"] = function(nm, args)
	print("Email/query",
		args.accountId,
		args.filter,
		args.sort,
		args.position,
		args.anchor,
		args.anchorOffset,
		args.limit,
		args.calculateTotal,
		args.collapseThreads
	)
	local primary_email = nm:config_get("user.primary_email")
	assert(args.accountId == escape_id(primary_email), "mismatched account id. TODO: other accounts?")

	local query = filter_to_query(args.filter)

	local sort
	if args.sort then
		for _, v in ipairs(args.sort) do
			if v.property == "receivedAt" then
				if v.isAscending then
					sort = "oldest-first"
				else
					sort = "newest-first"
				end
			else
				error "NYI"
			end
			if v.collation then
				error "NYI"
			end
		end
	end

	local offset = args.position

	if args.anchor then
		offset = nil
		error "NYI"
		-- Note: would need to compute `position` in response
	end

	local limit = args.limit

	local ids = json.Array{}
	for i, v in ipairs(nm:search(query, sort, offset, limit)) do
		ids[i] = escape_id(v)
	end

	local total
	if args.calculateTotal then
		total = nm:count(query)
	end

	local res = {
		accountId = args.accountId;
		queryState = nm:state_value(query);
		canCalculateChanges = true;
		position = offset or 0;
		ids = ids;
		total = total;
		limit = nil; -- This is only returned if the server set a limit or used a different limit than that given in the request.
	}
	return {res}
end

methods["Email/queryChanges"] = function(nm, args)
	print("Email/queryChanges",
		args.accountId,
		args.filter,
		args.sort,
		args.sinceQueryState,
		args.maxChanges,
		args.upToId,
		args.calculateTotal,
		args.collapseThreads
	)
	local primary_email = nm:config_get("user.primary_email")
	assert(args.accountId == escape_id(primary_email), "mismatched account id. TODO: other accounts?")

	local query = filter_to_query(args.filter)

	local sort
	if args.sort then
		for _, v in ipairs(args.sort) do
			if v.property == "receivedAt" then
				if v.isAscending then
					sort = "oldest-first"
				else
					sort = "newest-first"
				end
			else
				error "NYI"
			end
			if v.collation then
				error "NYI"
			end
		end
	end

	local sinceQueryState = args.sinceQueryState
	if type(sinceQueryState) ~= "string" then
		return nil, { type = "invalidArguments", detail = "invalid sinceQueryState" }
	end

	local removed = json.Array{}
	local added = json.Array{}
	 -- = nm:search(query, sort, offset, limit, sinceQueryState)

	local total
	if args.calculateTotal then
		total = nm:count(query)
	end

	local res = {
		accountId = args.accountId;
		oldQueryState = sinceQueryState;
		newQueryState = nm:state_value(query);
		total = total;
		removed = removed;
		added = added;
	}
	return {res}
end

local thread_known_properties = {
	id = true;
	emailIds = true;
}
local thread_default_properties = thread_known_properties

methods["Thread/get"] = function(nm, args)
	print("Thread/get", args.accountId, json.encode(args.ids), json.encode(args.properties))
	local primary_email = nm:config_get("user.primary_email")
	assert(args.accountId == escape_id(primary_email), "mismatched account id. TODO: other accounts?")

	local thread_list
	if args.ids ~= json.null then
		thread_list = {}
		for i, v in ipairs(args.ids) do
			thread_list[i] = assert(v:match("^T(.*)"), "invalid thread id")
		end
	elseif type(args.ids) ~= "table" then
		thread_list = nm:get_thread_ids("*")
	else
		return nil, { type = "invalidArguments", detail = "invalid ids" }
	end

	local properties = args.properties
	if properties == json.null or properties == nil then -- nil seen in JMAP demo webmail
		properties = thread_default_properties
	else
		local s = {}
		for _, v in ipairs(properties) do
			if not thread_known_properties[v] then
				error("unknown property")
			end
			s[v] = true
		end
		properties = s
	end

	local list = json.Array{}
	for i, thread_id in ipairs(thread_list) do
		local item = {
			id = "T" .. thread_id;
		}
		if properties.emailIds then
			local emailIds = json.Array{}
			for j, v in ipairs(nm:search("thread:" .. notmuch.quote(thread_id))) do
				emailIds[j] = escape_id(v)
			end
			item.emailIds = emailIds
		end
		list[i] = item
	end

	local res = {
		accountId = args.accountId;
		state = nm:state_value("*");
		list = list;
		notFound = json.Array{};
	}
	return {res}
end

local identity_known_properties = {
	id = true;
	name = true;
	email = true;
	replyTo = true;
	bcc = true;
	textSignature = true;
	htmlSignature = true;
	mayDelete = true;
}
local identity_default_properties = identity_known_properties
methods["Identity/get"] = function(nm, args)
	print("Identity/get", args.accountId, json.encode(args.ids), json.encode(args.properties))
	local primary_email = nm:config_get("user.primary_email")
	assert(args.accountId == escape_id(primary_email), "mismatched account id. TODO: other accounts?")

	if args.ids ~= json.null and args.ids ~= nil then -- nil seen from jmap-mua
		error("TODO")
	elseif type(args.ids) ~= "table" then
		-- TODO
	else
		return nil, { type = "invalidArguments", detail = "invalid ids" }
	end

	local properties = args.properties
	if properties == json.null or properties == nil then -- nil seen from jmap-mua
		properties = identity_default_properties
	else
		local s = {}
		for _, v in ipairs(properties) do
			if not identity_known_properties[v] then
				error("unknown property")
			end
			s[v] = true
		end
		properties = s
	end

	local list = json.Array{}
	-- TODO

	local res = {
		accountId = args.accountId;
		state = nm:state_value("*");
		list = list;
		notFound = json.Array{};
	}
	return {res}
end

return methods
