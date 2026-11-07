-- Access check for the status page (nginx access_by_lua_file): the browser's password dialog, the
-- password is STATUS_PIN from gateway.conf, the user name is ignored. Without a PIN nobody gets in.
-- A wrong answer waits a second, so a short PIN cannot be guessed quickly.

local function pin()
	local f = io.open("/etc/gateway/gateway.conf")
	if not f then return nil end
	for line in f:lines() do
		local v = line:match('^STATUS_PIN="?([^"]*)"?%s*$')
		if v and v ~= "" then
			f:close()
			return v
		end
	end
	f:close()
end

local p = pin()
local h = ngx.var.http_authorization
if p and h then
	local dec = ngx.decode_base64(h:match("^Basic%s+(.+)$") or "")
	if dec and dec:match(":(.*)$") == p then
		return
	end
	ngx.sleep(1)
end
ngx.header["WWW-Authenticate"] = 'Basic realm="TV gateway: PIN as password"'
return ngx.exit(401)
