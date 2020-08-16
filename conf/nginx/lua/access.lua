-- Copyright 2015-2016 CloudFlare
-- Copyright 2014-2015 Aaron Westendorf

local json = require("cjson")
local http = require("resty.http")

local uri         = ngx.var.uri
local uri_args    = ngx.req.get_uri_args()
local scheme      = ngx.var.scheme

local client_id         = ngx.var.ngo_client_id
local client_secret     = ngx.var.ngo_client_secret
local token_secret      = ngx.var.ngo_token_secret
local domain            = ngx.var.ngo_domain
local cb_scheme         = ngx.var.ngo_callback_scheme or scheme
local cb_server_name    = ngx.var.ngo_callback_host or ngx.var.server_name
local cb_uri            = ngx.var.ngo_callback_uri or "/_oauth"
local cb_url            = cb_scheme .. "://" .. cb_server_name .. cb_uri
local redirect_url      = cb_scheme .. "://" .. cb_server_name .. ngx.var.request_uri
local extra_validity    = tonumber(ngx.var.ngo_extra_validity or "0")
local whitelist         = ngx.var.ngo_whitelist or ""
local blacklist         = ngx.var.ngo_blacklist or ""
local secure_cookies    = ngx.var.ngo_secure_cookies == "true" or false
local http_only_cookies = ngx.var.ngo_http_only_cookies == "true" or false
local set_user          = ngx.var.ngo_user or false
local email_as_user     = ngx.var.ngo_email_as_user == "true" or false
local session_id        = uri_args["state"] or ngx.var.cookie_session
local session           = ngx.shared.session;

if whitelist:len() == 0 then
  whitelist = nil
end

if blacklist:len() == 0 then
  blacklist = nil
end

local function create_uuid (length)
  local index, pw, rnd = 0, ""
  local chars = {
    "abcdefghijklmnopqrstuvwxyz",
    "0123456789"
  }
  math.randomseed(os.clock())
  repeat
    index = index + 1
    rnd = math.random(chars[index]:len())
    if math.random(2) == 1 then
      pw = pw .. chars[index]:sub(rnd, rnd)
    else
      pw = chars[index]:sub(rnd, rnd) .. pw
    end
    index = index % #chars
  until pw:len() >= length
  return pw
end

local function check_domain(email, whitelist_failed)
  local oauth_domain = email:match("[^@]+@(.+)")
  -- if domain is configured, check it, if it isn't, permit request
  if domain:len() ~= 0 then
    if not string.find(" " .. domain .. " ", " " .. oauth_domain .. " ", 1, true) then
      if whitelist_failed then
        ngx.log(ngx.ERR, email .. " is not on " .. domain .. " nor in the whitelist")
      else
        ngx.log(ngx.ERR, email .. " is not on " .. domain)
      end
      return ngx.exit(ngx.HTTP_FORBIDDEN)
    end
  end
end

local function on_auth(email, token, expires)
  if blacklist then
    -- blacklisted user is always rejected
    if string.find(" " .. blacklist .. " ", " " .. email .. " ", 1, true) then
      ngx.log(ngx.ERR, email .. " is in blacklist")
      return ngx.exit(ngx.HTTP_FORBIDDEN)
    end
  end

  if whitelist then
    -- if whitelisted, no need check the if it's a valid domain
    if not string.find(" " .. whitelist .. " ", " " .. email .. " ", 1, true) then
      check_domain(email, true)
    end
  else
    -- empty whitelist, lets check if it's a valid domain
    check_domain(email, false)
  end


  if set_user then
    if email_as_user then
      ngx.var.ngo_user = email
    else
      ngx.var.ngo_user = email:match("([^@]+)@.+")
    end
  end
end

local function request_access_token(code)
  local request = http.new()

  request:set_timeout(7000)

  local res, err = request:request_uri("https://accounts.google.com/o/oauth2/token", {
    method = "POST",
    body = ngx.encode_args({
      code          = code,
      client_id     = client_id,
      client_secret = client_secret,
      redirect_uri  = cb_url,
      grant_type    = "authorization_code",
    }),
    headers = {
      ["Content-type"] = "application/x-www-form-urlencoded"
    },
    ssl_verify = true,
  })
  if not res then
    return nil, (err or "auth token request failed: " .. (err or "unknown reason"))
  end

  if res.status ~= 200 then
    return nil, "received " .. res.status .. " from https://accounts.google.com/o/oauth2/token: " .. res.body
  end

  return json.decode(res.body)
end

local function request_profile(token)
  local request = http.new()

  request:set_timeout(7000)

  local res, err = request:request_uri("https://www.googleapis.com/oauth2/v2/userinfo", {
    headers = {
      ["Authorization"] = "Bearer " .. token,
    },
    ssl_verify = true,
  })
  if not res then
    return nil, "auth info request failed: " .. (err or "unknown reason")
  end

  if res.status ~= 200 then
    return nil, "received " .. res.status .. " from https://www.googleapis.com/oauth2/v2/userinfo"
  end

  return json.decode(res.body)
end

local function is_authorized()
  local session_data = json.decode(session:get(session_id))
  local expires = session_data.expires
  local email = session_data.email
  local token = session_data.token

  local expected_token = ngx.encode_base64(ngx.hmac_sha1(token_secret, cb_server_name .. email .. expires))

  if token == expected_token and expires and expires > ngx.time() - extra_validity then
    session:set(session_id, json.encode(session_data), 3600)
    return true
  else
    return false
  end
end

local function redirect_to_auth()
  ngx.header["Set-Cookie"] = {"session=" .. session_id}

  -- google seems to accept space separated domain list in the login_hint, so use this undocumented feature.
  return ngx.redirect("https://accounts.google.com/o/oauth2/auth?" .. ngx.encode_args({
    client_id     = client_id,
    scope         = "email",
    response_type = "code",
    redirect_uri  = cb_url,
    state         = session_id,
    login_hint    = domain,
  }))
end

local function authorize()
  if uri ~= cb_uri then
    return redirect_to_auth()
  end

  if uri_args["error"] then
    ngx.log(ngx.ERR, "received " .. uri_args["error"] .. " from https://accounts.google.com/o/oauth2/auth")
    return ngx.exit(ngx.HTTP_FORBIDDEN)
  end

  local token, token_err = request_access_token(uri_args["code"])
  if not token then
    ngx.log(ngx.ERR, "got error during access token request: " .. token_err)
    return ngx.exit(ngx.HTTP_FORBIDDEN)
  end

  local profile, profile_err = request_profile(token["access_token"])
  if not profile then
    ngx.log(ngx.ERR, "got error during profile request: " .. profile_err)
    return ngx.exit(ngx.HTTP_FORBIDDEN)
  end

  local expires      = ngx.time() + token["expires_in"]
  local cookie_tail  = ";version=1;path=/;Max-Age=" .. extra_validity + token["expires_in"]
  if secure_cookies then
    cookie_tail = cookie_tail .. ";secure"
  end
  if http_only_cookies then
    cookie_tail = cookie_tail .. ";httponly"
  end

  local email      = profile["email"]
  local user_token = ngx.encode_base64(ngx.hmac_sha1(token_secret, cb_server_name .. email .. expires))

  -- Update session with data from auth response
  local session_data = json.decode(session:get(session_id))
  session_data.expires = expires
  session_data.email   = email
  session_data.token   = user_token
  session:set(session_id, json.encode(session_data), 3600)
  return ngx.redirect(session_data.original_url)
end

--------------------------------
-- Main code
--------------------------------
-- Flush expired sessions
ngx.shared.session:flush_expired()

-- Create new session if session_id is empty or session with session_id does not exists
if session_id == nil or session:get(session_id) == nil then
  session_id = create_uuid(32)
  local session_data = {
    ["id"] = session_id,
    ["original_url"] = cb_scheme .. "://" .. ngx.var.host .. ngx.var.request_uri,
    ["expires"] = 0,
    ["email"] = "",
    ["token"] = "",
  }
  session:set(session_id, json.encode(session_data), 300)
else
  session_data = json.decode(session:get(session_id))
  session_id = session_data.id
end

if not is_authorized() then
  authorize()
end

if uri == "/_oauth" then
  return ngx.redirect(session_data.original_url)
end
