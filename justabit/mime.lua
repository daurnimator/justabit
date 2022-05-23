local iconv = require "iconv"
local json = require "justabit.json"
local lpeg = require "lpeg"
-- local email_patterns = require "lpeg_patterns.email"
local email_patterns = require "justabit.lpeg"
local core = require "lpeg_patterns.core"

local EOF = lpeg.P(-1)
local printable_character = lpeg.R("\33\126")

local upper_hex = core.DIGIT + lpeg.S"ABCDEF"
local Q = lpeg.Cs((
   lpeg.P"=" * lpeg.C(upper_hex * upper_hex) / function(s) return string.char(tonumber(s, 16)) end
   + lpeg.P"_" / " "
   + (printable_character - lpeg.S("=?_"))
)^1) * EOF
local patt_7bit = lpeg.R("\0\127")^0 * EOF
local function decode_RFC2047(charset, encoding, text)
   local s
   if encoding == "q" then
      s = Q:match(text)
      if not s then
         -- On invalid Q encoding, just return the text as-is
         print("debug: invalid Q-encoding: " .. text)
         return text
      end
   elseif encoding == "b" then
      error "TODO: base64 decoding"
   else
      error "TODO: other encodings"
   end

   if charset == "utf-8" then
      assert(utf8.len(s)) -- check if valid utf8
      return s
   elseif charset == "us-ascii" then
      assert(patt_7bit:match(s), "invalid us-ascii")
      return s
   -- elseif charset == "iso-8859-1" and patt_7bit:match(s) then
   --    return s
   else
      -- error("TODO charset conversion: " .. charset)
      local converter, err = iconv.new("utf-8", charset)
      if not converter then
         error("TODO: better error handling: " .. err)
      end
      s, err = converter:iconv(s)
      if not s then
         error("TODO: better error handling: " .. err)
      end
      return s
   end
end
local encoded_word = email_patterns.encoded_word / decode_RFC2047

local function each_mime_header_line_iter(raw, pos)
   local start_of_line = pos
   :: findLF ::
   local s, e = raw:find("\n", pos, true)
   if s == nil then
      error "invalid message"
   elseif s == start_of_line then
      -- end of headers
      return nil
   end
   local next_line_start = e+1
   if raw:find("^[ \t]", next_line_start) then
      -- white space continuation
      pos = next_line_start
      goto findLF
   end
   return next_line_start, start_of_line, e-1
end

local function each_mime_header_line(raw_message)
   return each_mime_header_line_iter, raw_message, 1
end

-- JMAP 4.1.2 Header Fields Parsed Forms
-- TODO a lot of these formats have a "this form may only be fetched or set for the following header fields:"
local header_forms = {}

function header_forms.Raw(s)
   return s
end

local no_null_or_ctrl = lpeg.Cs((lpeg.S("\0") + core.CTL) / "" + lpeg.P(1))
local text_patt = lpeg.Cs(
   -- Any SP characters at the beginning of the value removed.
   core.WSP / ""
   + (
      -- > Unfolding is accomplished by simply removing any CRLF that is immediately followed by WSP.
      lpeg.P"\n " / " "
      -- Any syntactically correct encoded sections [@!RFC2047] with a known character set decoded.
      + encoded_word / function(s)
         -- Any NUL octets or control characters encoded per [@!RFC2047] are dropped from the decoded value.
         s = no_null_or_ctrl:match(s)
         -- Any text that looks like syntax per [@!RFC2047] but violates placement or white space rules per [@!RFC2047] MUST NOT be decoded.
         -- TODO
         return s
      end
      + email_patterns.atom
   )^0
)
function header_forms.Text(s)
   -- -- Unfold
   -- -- RFC 5322 Section 2.2.3:
   -- -- > Unfolding is accomplished by simply removing any CRLF that is immediately followed by WSP.
   -- s = s:gsub("\n ", " ")

   -- -- Any SP characters at the beginning of the value removed.
   -- s = s:gsub("^%s+", "", 1)

   -- -- Any syntactically correct encoded sections [@!RFC2047] with a known character set decoded.
   -- s = encoded_word:match(s)
   -- -- Any NUL octets or control characters encoded per [@!RFC2047] are dropped from the decoded value.
   -- -- TODO
   -- -- Any text that looks like syntax per [@!RFC2047] but violates placement or white space rules per [@!RFC2047] MUST NOT be decoded.
   -- -- TODO

   s = text_patt:match(s)

   -- The resulting unicode converted to Normalization Form C (NFC) form.
   -- TODO

   return s
end

local addresses_patt = lpeg.Ct(email_patterns.address_list^1) * EOF
local encoded_patt = lpeg.Cs((encoded_word + lpeg.P" " + (lpeg.P(1)-lpeg.P" ")^1)^0)
function header_forms.Addresses(s)
   local addresses = addresses_patt:match(s)
   if not addresses then
      return json.null
   end
   local r = json.Array{}
   for _, v in ipairs(addresses) do
      if v.members then
         goto continue
      end
      local name = v.display
      if name then
         name = encoded_patt:match(name)
      else
         name = json.null
      end
      table.insert(r, {
         name = name;
         email = v[1];
      })
      :: continue ::
   end
   return r
end

function header_forms.GroupedAddresses(s)
   local r = addresses_patt:match(s)
   if not r then
      return json.null
   end
   setmetatable(r, json.array_mt)
   for i, v in ipairs(r) do
      local name
      local addresses = json.Array{}
      if v.members then
         name = encoded_patt:match(v.display)
         for j, vv in ipairs(v.members) do
            local member_name = vv.display
            if member_name then
               member_name = encoded_patt:match(member_name)
            else
               member_name = json.null
            end
            addresses[j] = {
               name = member_name;
               email = vv[1];
            }
         end
      else
         name = json.null
         addresses[1] = v[1]
      end
      r[i] = {
         name = name;
         addresses = addresses;
      }
   end
   return r
end

local msg_ids = lpeg.Ct(email_patterns.msg_id^1) * EOF
function header_forms.MessageIds(s)
   local ids = msg_ids:match(s)
   if ids then
      return setmetatable(ids, json.array_mt)
   else
      return json.null
   end
end

local date_time do
   local C = lpeg.C
   local Cg = lpeg.Cg
   local P = lpeg.P
   local R = lpeg.R
   local S = lpeg.S

   local FWS = email_patterns.FWS
   local CFWS = email_patterns.CFWS
   local DIGIT = core.DIGIT
   local _2DIGIT = DIGIT * DIGIT
   local _4DIGIT = _2DIGIT * _2DIGIT

   local function tonumber_10(s)
      return tonumber(s, 10)
   end

   -- captured value follow's Lua's os.date yday convention
   local day_name = (P"Mon" + P"Tue" + P"Wed" + P"Thu" + P"Fri" + P"Sat" + P"Sun") / {
      Mon = 2;
      Tue = 3;
      Wed = 4;
      Thu = 5;
      Fri = 6;
      Sat = 7;
      Sun = 1;
   }
   local obs_day_of_week = CFWS^-1 * day_name * CFWS^-1
   local day_of_week = obs_day_of_week
   local obs_day = CFWS^-1 * (_2DIGIT^1 / tonumber_10) * CFWS^-1
   local day = obs_day / 1
   local month = (P"Jan"+ P"Feb"+ P"Mar"+ P"Apr"+ P"May"+ P"Jun"+ P"Jul"+ P"Aug"+ P"Sep"+ P"Oct"+ P"Nov"+ P"Dec") / {
      Jan = 1;
      Feb = 2;
      Mar = 3;
      Apr = 4;
      May = 5;
      Jun = 6;
      Jul = 7;
      Aug = 8;
      Sep = 9;
      Oct = 10;
      Nov = 11;
      Dec = 12;
   }
   local obs_year = CFWS^-1 * DIGIT^2 * CFWS^-1 / function(y)
      local r = tonumber_10(y)

      -- If a two digit year is encountered whose value is between 00 and 49,
      -- the year is interpreted by adding 2000, ending up with a value between 2000 and 2049.
      if #y == 2 and r < 50 then
         return r + 2000
      end

      -- If a two digit year is encountered with a value between 50 and 99,
      -- or any three digit year is encountered, the year is interpreted by adding 1900.
      if #y <= 3 then
         return r + 1900
      end

      return r
   end
   local year = obs_year / 1
   local date = Cg(day, "day") * Cg(month, "month") * Cg(year, "year")

   local obs_hour = CFWS^-1 * (_2DIGIT / tonumber_10) * CFWS^-1
   local hour = obs_hour / 1
   local obs_minute = CFWS^-1 * (_2DIGIT / tonumber_10) * CFWS^-1
   local minute = obs_minute / 1
   local obs_second = CFWS^-1 * (_2DIGIT / tonumber_10) * CFWS^-1
   local second = obs_second / 1
   local time_of_day = Cg(hour, "hour") * P":" * Cg(minute, "min") * (P":" * Cg(second, "sec"))^-1
   local obs_zone = (P"UT" + P"GMT") / "+0000"
      + P"EST" / "-0500"
      + P"EDT" / "-0400"
      + P"CST" / "-0600"
      + P"CDT" / "-0500"
      + P"MST" / "-0700"
      + P"MDT" / "-0600"
      + P"PST" / "-0800"
      + P"PDT" / "-0700"
      + R("\65\73", "\75\90", "\97\105", "\107\122") / "-0000"
   -- the FWS isn't optional in RFC5322
   local zone = FWS^-1 / 0 * C(S"+-" * _4DIGIT) + obs_zone
   local time = time_of_day * Cg(zone, "zone")

   date_time = (Cg(day_of_week, "wday") * P",")^-1 * date * time * CFWS^-1
   require"luassert".same("+0100", zone:match(" +0100"))
   require"luassert".same({hour=2, min=15, sec=14}, lpeg.Ct(time_of_day):match("02:15:14"))
   require"luassert".same({hour=2, min=15, sec=14, zone="+0100"}, lpeg.Ct(time):match("02:15:14 +0100"))
   require"luassert".same({year=2022, month=5, day=22, hour=2, min=15, sec=14, zone="+0100", wday=1}, lpeg.Ct(date_time):match("Sun, 22 May 2022 02:15:14 +0100"))
end

local date_time_patt = lpeg.Ct(date_time) * EOF
function header_forms.Date(s)
   local d = date_time_patt:match(s)
   assert(d, "invalid date")
   return string.format(
      "%04d-%02d-%02dT%02d:%02d:%02d%s:%s",
      d.year, d.month, d.day, d.hour, d.min, d.sec,
      d.zone:sub(1,3), d.zone:sub(4,5)
   )
end

function header_forms.URLs(s)
   error "NYI"
end

return {
   each_mime_header_line = each_mime_header_line;
   header_forms = header_forms;
}
