local lpeg = require "lpeg"
local core = require "lpeg_patterns.core"

local P = lpeg.P
local R = lpeg.R
local S = lpeg.S
local V = lpeg.V
local C = lpeg.C
local Cg = lpeg.Cg
local Cs = lpeg.Cs
local Ct = lpeg.Ct

local printable_character = lpeg.R("\33\126")

local ALPHA = core.ALPHA
local CHAR = core.CHAR
local CRLF = core.CRLF
local CTL = core.CTL
local DIGIT = core.DIGIT
local DQUOTE = core.DQUOTE
local WSP = core.WSP
local VCHAR = core.VCHAR

local obs_NO_WS_CTL = R("\1\8", "\11\12", "\14\31") + P"\127"

local obs_qp = Cg(P"\\" * C(P"\0" + obs_NO_WS_CTL + core.LF + core.CR))
local quoted_pair = Cg(P"\\" * C(VCHAR + WSP)) + obs_qp

-- Folding White Space
local FWS = (WSP^0 * CRLF)^-1 * WSP^1 / " " -- Fold whitespace into a single " "

-- Comments
local ctext   = R"\33\39" + R"\42\91" + R"\93\126"
local comment = P {
   V"comment" ;
   ccontent = ctext + quoted_pair + V"comment" ;
   comment = P"("* (FWS^-1 * V"ccontent")^0 * FWS^-1 * P")";
}
local CFWS = ((FWS^-1 * comment)^1 * FWS^-1 + FWS ) / 0

-- Atom
local specials      = S[=[()<>@,;:\".[]]=]
local atext         = CHAR-specials-P" "-CTL
local atom          = CFWS^-1 * C(atext^1) * CFWS^-1
local dot_atom_text = C(atext^1 * ( P"." * atext^1 )^0)
local dot_atom      = CFWS^-1 * dot_atom_text * CFWS^-1

-- Quoted Strings
local qtext              = S"\33"+R("\35\91","\93\126")
local qcontent           = qtext + quoted_pair
local quoted_string_text = DQUOTE * Cs((FWS^-1 * qcontent)^0 * FWS^-1) * DQUOTE
local quoted_string      = CFWS^-1 * quoted_string_text * CFWS^-1

-- Miscellaneous Tokens
local word = atom + quoted_string
local obs_phrase = Cs(word / 1 * (word / 1 + P"." + CFWS / " ")^0)
local phrase = obs_phrase -- obs_phrase is more broad than `word^1`, it's really the same but allows "."

-- Addr-spec
local obs_dtext = obs_NO_WS_CTL + quoted_pair
local dtext = R("\33\90", "\94\126") + obs_dtext
local domain_literal_text = P"[" * Cs((FWS^-1 * dtext)^0 * FWS^-1) * P"]"

local domain_text = dot_atom_text + domain_literal_text
local local_part_text = dot_atom_text + quoted_string_text
local addr_spec_text = local_part_text * P"@" * domain_text

local domain_literal = CFWS^-1 * domain_literal_text * CFWS^-1
local obs_domain = Ct(atom * (C"." * atom)^0) / table.concat
local domain = obs_domain + dot_atom + domain_literal
local obs_local_part = Ct(word * (C"." * word)^0) / table.concat
local local_part = obs_local_part + dot_atom + quoted_string
local addr_spec = Cg(local_part, "local-part") * P"@" * Cg(domain, "domain")

local display_name = phrase
local obs_domain_list = (CFWS + P",")^0 * P"@" * domain
   * (P"," * CFWS^-1 * (P"@" * domain)^-1)^0
local obs_route = Ct(obs_domain_list) * P":"
local obs_angle_addr = CFWS^-1 * P"<" * Cg(obs_route, "route") * C(addr_spec) * P">" * CFWS^-1
local angle_addr = CFWS^-1 * P"<" * C(addr_spec) * P">" * CFWS^-1
   + obs_angle_addr
local name_addr = Cg(display_name^-1, "display") * angle_addr
local mailbox = name_addr + C(addr_spec)

-- https://www.rfc-editor.org/rfc/rfc5322#section-2.2
-- Header fields are lines beginning with a field name, followed by a
-- colon (":"), followed by a field body, and terminated by CRLF.  A
-- field name MUST be composed of printable US-ASCII characters (i.e.,
-- characters that have values between 33 and 126, inclusive), except
-- colon.  A field body may be composed of printable US-ASCII characters
-- as well as the space (SP, ASCII value 32) and horizontal tab (HTAB,
-- ASCII value 9) characters (together known as the white space
-- characters, WSP).  A field body MUST NOT include CR and LF except
-- when used in "folding" and "unfolding", as described in section
-- 2.2.3.  All field bodies MUST conform to the syntax described in
-- sections 3 and 4 of this specification.
-- local ftext = S("\33\57","\59\126")
-- local field_name = ftext^1
-- local header_field_body = R("\33\126") + FWS

-- RFC 5322 Section 3.4
local obs_mbox_list = (CFWS^-1 * P",")^0 * Ct(mailbox) * (P"," * (Ct(mailbox) + CFWS)^-1)^0
-- mailbox_list is a super-set of obs_mbox_list that allowed empty fields
local mailbox_list = obs_mbox_list
local obs_group_list = (CFWS^-1 * P",")^1 * CFWS^-1
local group_list = mailbox_list + CFWS + obs_group_list
local group = Cg(display_name, "display") * P":" * Cg(Ct(group_list^-1), "members") * P";" * CFWS^-1
local address = mailbox + group
local obs_addr_list = (CFWS^-1 * P",")^0 * Ct(address) * (P"," * (Ct(address) + CFWS)^-1)^0
-- address_list is a super-set of obs_addr_list that allowed empty fields
local address_list = obs_addr_list

-- RFC 5322 Section 4.5.4
local obs_id_left = local_part
local obs_id_right = domain

-- RFC 5322 Section 3.6.4
local no_fold_literal = P"[" * dtext^0 * P"]"
local id_left = dot_atom_text + obs_id_left
local id_right = dot_atom_text + no_fold_literal + obs_id_right
-- Semantically, the angle bracket characters are not part of the
-- msg-id; the msg-id is what is contained between the two angle bracket
-- characters.
local msg_id = CFWS^-1 * P"<" * C(id_left * P"@" * id_right) * ">" * CFWS^-1

-- RFC 5987
local mime_charsetc = ALPHA + DIGIT + S"!#$%&+-^_`{}~"
local mime_charset = C(mime_charsetc^1)

-- RFC 2047
local charset = mime_charset / string.lower
local encoding = mime_charset / string.lower
local encoded_text = (printable_character - S"?")^1
local encoded_word = P"=?" * charset * P"?" * encoding * P"?" * C(encoded_text) * P"?="

return {
   obs_NO_WS_CTL = obs_NO_WS_CTL;
   obs_qp = obs_qp;
   quoted_pair = quoted_pair;
   FWS = FWS;
   ctext = ctext;
   comment = comment;
   CFWS = CFWS;
   specials = specials;
   atext = atext;
   atom = atom;
   dot_atom_text = dot_atom_text;
   dot_atom = dot_atom;
   qtext = qtext;
   qcontent = qcontent;
   quoted_string_text = quoted_string_text;
   quoted_string = quoted_string;
   word = word;
   obs_phrase = obs_phrase;
   phrase = phrase;
   obs_dtext = obs_dtext;
   dtext = dtext;
   domain_literal_text = domain_literal_text;
   domain_text = domain_text;
   local_part_text = local_part_text;
   addr_spec_text = addr_spec_text;
   domain_literal = domain_literal;
   obs_domain = obs_domain;
   domain = domain;
   obs_local_part = obs_local_part;
   local_part = local_part;
   addr_spec = addr_spec;
   display_name = display_name;
   obs_domain_list = obs_domain_list;
   obs_route = obs_route;
   obs_angle_addr = obs_angle_addr;
   angle_addr = angle_addr;
   name_addr = name_addr;
   mailbox = mailbox;
   -- ftext = ftext;
   -- field_name = field_name;
   -- header_field_body = header_field_body;
   obs_mbox_list = obs_mbox_list;
   mailbox_list = mailbox_list;
   obs_group_list = obs_group_list;
   group_list = group_list;
   group = group;
   address = address;
   obs_addr_list = obs_addr_list;
   address_list = address_list;
   obs_id_left = obs_id_left;
   obs_id_right = obs_id_right;
   no_fold_literal = no_fold_literal;
   id_left = id_left;
   id_right = id_right;
   msg_id = msg_id;
   mime_charsetc = mime_charsetc;
   mime_charset = mime_charset;
   charset = charset;
   encoding = encoding;
   encoded_text = encoded_text;
   encoded_word = encoded_word;
}
