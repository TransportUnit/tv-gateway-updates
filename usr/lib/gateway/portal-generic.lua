-- Generic captive-portal page analysis (Lua 5.1, no modules).
--   lua portal-generic.lua candidates PAGE URL -> requests worth trying, best first, one per line:
--                                                "METHOD\tURL\tBODY\tLABEL\tSIGNATURE" (exit 0), or a reason (exit 1)
--   lua portal-generic.lua login    PAGE URL  -> the best candidate as "METHOD\nURL\nBODY" (for site recipes)
--   lua portal-generic.lua refresh  PAGE URL  -> meta-refresh target URL (exit 0), or exit 1
--   lua portal-generic.lua describe PAGE URL  -> forms, fields and scripts, for the capture
--   lua portal-generic.lua scripts  PAGE URL  -> absolute URLs of external scripts, one per line
-- Not a browser: it only understands plain HTML forms. JavaScript-only portals are reported, not solved.

local mode, page_file, page_url = arg[1], arg[2], arg[3] or ""

local f = io.open(page_file or "", "rb")
if not f then print("cannot read page") os.exit(1) end
local html = f:read("*a")
f:close()
html = html:gsub("<!%-%-.-%-%->", "")

local function decode(s)
	s = s:gsub("&#[xX](%x+);", function(h) return string.char(tonumber(h, 16) % 256) end)
	s = s:gsub("&#(%d+);", function(d) return string.char(tonumber(d) % 256) end)
	return (s:gsub("&quot;", '"'):gsub("&#39;", "'"):gsub("&apos;", "'"):gsub("&lt;", "<")
		:gsub("&gt;", ">"):gsub("&nbsp;", " "):gsub("&amp;", "&"))
end

local function attrs(s)
	local a = {}
	s = s:gsub('([%w_:%-]+)%s*=%s*(["\'])(.-)%2', function(k, _, v) a[k:lower()] = decode(v) return " " end)
	s = s:gsub("([%w_:%-]+)%s*=%s*([^%s>]+)", function(k, v) a[k:lower()] = decode(v) return " " end)
	for k in s:gmatch("([%w_:%-]+)") do
		k = k:lower()
		if a[k] == nil then a[k] = "" end
	end
	return a
end

-- Remove "." and ".." path segments.
local function normalize(u)
	local pre, path, rest = u:match("^(%a[%w+.-]*://[^/?#]*)(/[^?#]*)(.*)$")
	if not pre then return u end
	local segs, out = {}, {}
	for seg in (path .. "/"):gmatch("([^/]*)/") do table.insert(segs, seg) end
	for i = 2, #segs do
		if segs[i] == ".." then
			if #out > 0 then table.remove(out) end
		elseif segs[i] ~= "." then
			table.insert(out, segs[i])
		end
	end
	if segs[#segs] == "." or segs[#segs] == ".." then table.insert(out, "") end
	return pre .. "/" .. table.concat(out, "/") .. rest
end

local function resolve_raw(base, ref)
	ref = (ref or ""):gsub("#.*$", ""):gsub("^%s+", ""):gsub("%s+$", "")
	base = base:gsub("#.*$", "")
	if ref == "" then return base end
	if ref:match("^%a[%w+.-]*:") then return ref end
	local scheme, host = base:match("^(%a[%w+.-]*:)//([^/?]*)")
	if not scheme then return ref end
	if ref:sub(1, 2) == "//" then return scheme .. ref end
	if ref:sub(1, 1) == "/" then return scheme .. "//" .. host .. ref end
	if ref:sub(1, 1) == "?" then return (base:gsub("%?.*$", "")) .. ref end
	local dir = base:gsub("%?.*$", ""):match("^(.*/)") or (base .. "/")
	if dir == scheme .. "//" then dir = base .. "/" end
	return dir .. ref
end

local function resolve(base, ref) return normalize(resolve_raw(base, ref)) end

local function urlencode(s)
	return (s:gsub("\n", "\r\n"):gsub("([^%w%-_%.~ ])", function(c)
		return string.format("%%%02X", c:byte()) end):gsub(" ", "+"))
end

-- Walk all tags in order; collect forms with their fields, and page-level facts.
local forms, scripts, refresh, title = {}, {}, nil, nil
local form, select_field, button
local pos = 1
while true do
	local s, e, close, name, rest = html:find("<(/?)([%a][%w]*)([^>]*)>", pos)
	if not s then break end
	pos = e + 1
	name = name:lower()
	local a = close == "" and attrs(rest) or {}
	if name == "form" then
		if close == "" then
			form = { attrs = a, fields = {}, index = #forms + 1 }
			table.insert(forms, form)
		else
			form = nil
		end
	elseif close == "" and name == "input" and form then
		table.insert(form.fields, { tag = "input", type = (a.type or "text"):lower(), name = a.name,
			value = a.value, checked = a.checked ~= nil, disabled = a.disabled ~= nil })
	elseif name == "button" and form then
		if close == "" then
			button = { tag = "button", type = (a.type or "submit"):lower(), name = a.name, value = a.value or "",
				disabled = a.disabled ~= nil, text_from = e + 1 }
			table.insert(form.fields, button)
		elseif button then
			button.text = decode(html:sub(button.text_from, s - 1):gsub("<[^>]*>", " ")):gsub("%s+", " ")
			button = nil
		end
	elseif name == "select" then
		select_field = nil
		if close == "" and form and a.name then
			select_field = { tag = "select", type = "select", name = a.name }
			table.insert(form.fields, select_field)
		end
	elseif close == "" and name == "option" and select_field then
		if select_field.value == nil or a.selected ~= nil then select_field.value = a.value or "" end
	elseif close == "" and name == "script" and a.src then
		table.insert(scripts, resolve(page_url, a.src))
	elseif close == "" and name == "meta" and (a["http-equiv"] or ""):lower() == "refresh" then
		local u = (a.content or ""):match("[uU][rR][lL]%s*=%s*['\"]?([^'\"]+)")
		if u then refresh = resolve(page_url, u) end
	end
end
title = html:match("<[tT][iI][tT][lL][eE][^>]*>(.-)</")
local inline_scripts = 0
for _ in html:gmatch("<[sS][cC][rR][iI][pP][tT][^>]*>[^<]") do inline_scripts = inline_scripts + 1 end

local function has(fm, t)
	for _, fd in ipairs(fm.fields) do if fd.type == t then return true end end
	return false
end

-- How much a button or radio value looks like "accept and go online" (German and English).
local GOOD = { "akzept", "accept", "agree", "zustimm", "einverstanden", "connect", "verbind", "anmeld", "login",
	"log in", "sign in", "weiter", "continue", "start", "internet", "surf", "los", "ok", "ja", "yes", "submit", "go" }
local BAD = { "abbrech", "cancel", "ablehn", "decline", "reject", "disagree", "nicht", "nein", "no", "zurück",
	"zurueck", "back", "abmeld", "logout", "search", "such", "code", "passw", "voucher", "gutschein", "regist" }
local function intent(s)
	s = " " .. (s or ""):lower() .. " "
	local score = 0
	for _, w in ipairs(BAD) do
		if s:find(w, 1, true) then score = score - 2 end
	end
	for _, w in ipairs(GOOD) do
		if s:find(w, 1, true) then score = score + 1 end
	end
	return score
end

local function is_submit(fd)
	return fd.type == "submit" or fd.type == "image" or (fd.tag == "button" and fd.type == "submit")
end

-- Forms worth trying: no password field (we have no credentials), checkbox and submit preferred.
local function ranked_forms()
	local list = {}
	for _, fm in ipairs(forms) do
		if not has(fm, "password") then
			local score = #fm.fields
			if has(fm, "checkbox") then score = score + 20 end
			for _, fd in ipairs(fm.fields) do
				if is_submit(fd) then score = score + 10 break end
			end
			if (fm.attrs.method or ""):lower() == "post" then score = score + 5 end
			score = score + 3 * intent(fm.attrs.action)
			table.insert(list, { form = fm, score = score })
		end
	end
	table.sort(list, function(x, y)
		if x.score ~= y.score then return x.score > y.score end
		return x.form.index < y.form.index
	end)
	return list
end

-- One request for form fm, sending submit button sb (nil: no button field).
local function build(fm, sb)
	local parts, radios, names = {}, {}, {}
	local function add(k, v)
		table.insert(parts, urlencode(k) .. "=" .. urlencode(v))
		names[#names + 1] = k
	end
	for _, fd in ipairs(fm.fields) do
		local t = fd.type
		if fd.name and fd.name ~= "" and not is_submit(fd) then
			if t == "checkbox" then
				-- Accepting the terms is the whole point: tick every checkbox.
				add(fd.name, fd.value or "on")
			elseif t == "radio" then
				local r = radios[fd.name]
				local v = fd.value or "on"
				local sc = intent(v) * 10 + (fd.checked and 1 or 0)
				if not r or sc > r.score then radios[fd.name] = { value = v, score = sc } end
			elseif t ~= "reset" and t ~= "file" and t ~= "button" then
				add(fd.name, fd.value or "")
			end
		end
	end
	for k, r in pairs(radios) do add(k, r.value) end
	-- Disabled counts too: portals grey out the button until JavaScript sees the ticked box.
	table.sort(names)
	if sb and sb.name and sb.name ~= "" then table.insert(parts, urlencode(sb.name) .. "=" .. urlencode(sb.value or "")) end
	local method = (fm.attrs.method or "get"):upper() == "POST" and "POST" or "GET"
	local url = resolve(page_url, fm.attrs.action)
	-- Signature: which form this is, independent of tokens and of the button; tells a new step from a retry.
	local sig = method .. " " .. (url:gsub("%?.*$", "")) .. " " .. table.concat(names, ",")
	local label = string.format("form%d %s submit=%s", fm.index, sig,
		sb and ((sb.name or "") .. ":" .. (sb.value or "") .. ":" .. (sb.text or "")) or "-")
	return method, url, table.concat(parts, "&"), (label:gsub("\t", " ")), sig
end

-- All requests worth trying, best first; the variant that worked last time (GATEWAY_HINT) leads.
local function candidates()
	local out = {}
	for _, rf in ipairs(ranked_forms()) do
		local fm, subs = rf.form, {}
		for i, fd in ipairs(fm.fields) do
			if is_submit(fd) then
				table.insert(subs, { fd = fd, score = intent((fd.value or "") .. " " .. (fd.text or "") .. " " .. (fd.name or "")), i = i })
			end
		end
		table.sort(subs, function(x, y)
			if x.score ~= y.score then return x.score > y.score end
			return x.i < y.i
		end)
		for _, sbx in ipairs(subs) do
			if sbx.score >= 0 or #subs == 1 then table.insert(out, { build(fm, sbx.fd) }) end
		end
		table.insert(out, { build(fm, nil) })
	end
	local hint = os.getenv("GATEWAY_HINT")
	if hint and hint ~= "" then
		for i, c in ipairs(out) do
			if c[4] == hint then table.remove(out, i) table.insert(out, 1, c) break end
		end
	end
	while #out > 8 do table.remove(out) end
	return out
end

local function no_form_reason()
	return string.format("no usable form (%d forms, %d external + %d inline scripts)%s", #forms, #scripts,
		inline_scripts, (#scripts + inline_scripts > 0) and ", JavaScript portal likely" or "")
end

if mode == "refresh" then
	if refresh and refresh ~= page_url then print(refresh) os.exit(0) end
	os.exit(1)
elseif mode == "scripts" then
	for _, s in ipairs(scripts) do print(s) end
elseif mode == "candidates" then
	local c = candidates()
	if #c == 0 then print(no_form_reason()) os.exit(1) end
	for _, x in ipairs(c) do print(table.concat(x, "\t")) end
elseif mode == "login" then
	local c = candidates()
	if #c == 0 then print(no_form_reason()) os.exit(1) end
	print(c[1][1]) print(c[1][2]) print(c[1][3])
elseif mode == "describe" then
	print("url: " .. page_url)
	print("title: " .. (title and decode(title):gsub("%s+", " ") or "-"))
	print(string.format("forms: %d, external scripts: %d, inline scripts: %d", #forms, #scripts, inline_scripts))
	if refresh then print("meta refresh: " .. refresh) end
	for i, fm in ipairs(forms) do
		print(string.format("form %d: method=%s action=%s -> %s", i, fm.attrs.method or "get", fm.attrs.action or "",
			resolve(page_url, fm.attrs.action)))
		for _, fd in ipairs(fm.fields) do
			print(string.format("  %s type=%s name=%s value=%s%s%s%s", fd.tag, fd.type, fd.name or "-",
				fd.type == "password" and "<redacted>" or (fd.value or ""), fd.text and (" text=" .. fd.text) or "",
				fd.checked and " checked" or "", fd.disabled and " disabled" or ""))
		end
	end
	for _, s in ipairs(scripts) do print("script: " .. s) end
	local c = candidates()
	if #c == 0 then print("generic login: no usable form") end
	for i, x in ipairs(c) do print(string.format("candidate %d: %s %s %s", i, x[1], x[2], x[3])) end
else
	print("usage: portal-generic.lua login|candidates|refresh|describe|scripts PAGE URL")
	os.exit(1)
end
