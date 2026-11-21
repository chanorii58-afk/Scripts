local env = (getgenv and getgenv()) or _G
if env.__BoomboxCleanup then pcall(env.__BoomboxCleanup) end
if not game:IsLoaded() then game.Loaded:Wait() end

local Players = game:GetService("Players")
local TextChatService = game:GetService("TextChatService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local Workspace = game:GetService("Workspace")
local StarterGui = game:GetService("StarterGui")
while not Players.LocalPlayer do task.wait() end
local LocalPlayer = Players.LocalPlayer

local CONFIG = {
	PublicChat = true,
	ChatGap = 1.3,
	PerPage = 10,
	FetchSize = 30,
	MaxPage = 1000,

	Access = "everyone",
	Cooldown = 2.5,

	Strict = true,
	StrictDepth = 60,
	StrictScanMax = 200,
	MaxAlbums = 10,
	MaxTracks = 100,
	MaxVolume = 10,
	MaxQueue = 150,
	MaxPerPlayer = 10,
	SfxMax = 10,
	ShortMax = 45,
	LongMin = 300,
}

local NONE_MSG = "audio may have been removed/banned"

local conns, made, gone = {}, {}, false
local cleanupFns = {}
local OWN_GUI = { BoomboxToggles = true, BoomboxBanner = true }
local UI = { fly = false, hide = false, watch = function() end }
local function track(c)
	conns[#conns + 1] = c
	return c
end
local unpack = table.unpack or unpack

local function trim(s) return (tostring(s or ""):match("^%s*(.-)%s*$")) end
local function clean(s)
	s = tostring(s or "")
	s = s:gsub("%c+", " "):gsub("%s+", " ")
	return trim(s)
end

local function banner(text, r, g, b, secs)
	pcall(function()
		local pg = LocalPlayer:FindFirstChild("PlayerGui")
		if not pg then return end
		local sg = Instance.new("ScreenGui")
		sg.Name = "BoomboxBanner"
		sg.ResetOnSpawn = false
		sg.IgnoreGuiInset = true
		sg.DisplayOrder = 2147483645
		local l = Instance.new("TextLabel")
		l.Position = UDim2.fromOffset(10, 60)
		l.Size = UDim2.new(1, -20, 0, 0)
		l.AutomaticSize = Enum.AutomaticSize.Y
		l.BackgroundColor3 = Color3.fromRGB(r, g, b)
		l.BackgroundTransparency = 0.1
		l.TextColor3 = Color3.new(1, 1, 1)
		l.TextWrapped = true
		l.TextSize = 15
		l.Font = Enum.Font.GothamBold
		l.Text = text
		l.Parent = sg
		sg.Parent = pg
		task.delay(secs, function() sg:Destroy() end)
	end)
end
local function note(text) banner(text, 40, 90, 160, 8) end
local function problem(text) banner(text, 190, 60, 60, 20) end

local function localSay(text)
	local ok = pcall(function()
		local channels = TextChatService:FindFirstChild("TextChannels")
		local ch = channels and (channels:FindFirstChild("RBXSystem") or channels:FindFirstChild("RBXGeneral"))
		ch:DisplaySystemMessage(text)
	end)
	if not ok then pcall(function() StarterGui:SetCore("ChatMakeSystemMessage", { Text = text }) end) end
end

local lastEcho = 0
local hookedChannels = {}
local dispatch
local function hookChannels()
	pcall(function()
		local channels = TextChatService:FindFirstChild("TextChannels")
		if not channels then return end
		for _, c in ipairs(channels:GetChildren()) do
			if c:IsA("TextChannel") and not hookedChannels[c] then
				hookedChannels[c] = true
				track(c.MessageReceived:Connect(function(m)
					local src = m.TextSource
					if not src then return end
					if src.UserId == LocalPlayer.UserId then lastEcho = os.clock() end

					local plr = Players:GetPlayerByUserId(src.UserId)
					if plr and dispatch and type(m.Text) == "string" then dispatch(m.Text, plr) end
				end))
			end
		end
	end)
end

local function chatChannels()
	local list, seen = {}, {}
	local function add(c)
		if c and not seen[c] then
			seen[c] = true
			list[#list + 1] = c
		end
	end
	local channels = TextChatService:FindFirstChild("TextChannels")
	if channels then
		add(channels:FindFirstChild("RBXGeneral"))
		local cfg = TextChatService:FindFirstChildOfClass("ChatInputBarConfiguration")
		if cfg then add(cfg.TargetTextChannel) end
		for _, c in ipairs(channels:GetChildren()) do
			if c:IsA("TextChannel") and c.Name ~= "RBXSystem" then add(c) end
		end
	end
	return list
end

local function rawSend(text)
	local details = {}
	local t0 = os.clock()
	local function echoed(wait)
		local t = os.clock()
		while os.clock() - t < wait and lastEcho < t0 do task.wait(0.1) end
		return lastEcho >= t0
	end
	hookChannels()
	if TextChatService.ChatVersion == Enum.ChatVersion.TextChatService then
		for _, ch in ipairs(chatChannels()) do
			t0 = os.clock()
			local ok, res = pcall(function() return ch:SendAsync(text) end)
			local name = "Success"
			if not ok then
				name = "error"
				details[#details + 1] = ch.Name .. ": " .. tostring(res):sub(1, 70)
			else
				pcall(function() if res and res.Status then name = res.Status.Name end end)
				details[#details + 1] = ch.Name .. " = " .. name
			end
			if name == "Floodchecked" then return "flood", details end
			if name == "InvalidPrivacySettings" or name == "InvalidTextChannelPermissions" then return "blocked", details end
			if name == "TextFilterFailed" then return "filtered", details end
			if ok and (name == "Success" or name == "Sending" or echoed(2.5)) then return "ok", details end
		end
	end
	local ev = ReplicatedStorage:FindFirstChild("DefaultChatSystemChatEvents")
	local say = ev and ev:FindFirstChild("SayMessageRequest")
	if say then
		t0 = os.clock()
		say:FireServer(text, "All")
		details[#details + 1] = "legacy chat remote fired"
		echoed(2.5)
		return "ok", details
	end
	details[#details + 1] = "no chat system found (ChatVersion = " .. tostring(TextChatService.ChatVersion) .. ")"
	return "fail", details
end

local EXPLAIN = {
	blocked = "Roblox says this account can't chat (account chat settings / parental controls).",
	fail = "This game has no normal Roblox chat I can send through (custom chat?).",
	filtered = "Roblox's filter rejected the message.",
}

local chatQueue, chatWorker, lastChatT, lastBanner = {}, false, 0, 0
local function sendChat(text)
	text = tostring(text):gsub("^[/%.!]+%s*", ""):sub(1, 200)
	if text == "" then return end
	if not CONFIG.PublicChat then
		localSay(text)
		return
	end
	if #chatQueue >= 20 then return end
	chatQueue[#chatQueue + 1] = { text = text, tries = 0 }
	if chatWorker then return end
	chatWorker = true
	task.spawn(function()
		while #chatQueue > 0 and not gone do
			local item = table.remove(chatQueue, 1)
			local gap = CONFIG.ChatGap - (os.clock() - lastChatT)
			if gap > 0 then task.wait(gap) end
			lastChatT = os.clock()
			local okc, r, details = pcall(rawSend, item.text)
			if not okc then r, details = "fail", { tostring(r):sub(1, 90) } end
			if r == "flood" and item.tries < 3 then
				item.tries = item.tries + 1
				table.insert(chatQueue, 1, item)
				task.wait(4)
			elseif r ~= "ok" and r ~= "flood" and os.clock() - lastBanner > 20 then
				lastBanner = os.clock()
				problem("CHAT PROBLEM (" .. r .. "): " .. (EXPLAIN[r] or "") .. " Details: " .. table.concat(details or {}, "; "))
			end
		end
		chatWorker = false
	end)
end

local function sendList(head, entries, sep)
	sep = sep or " | "
	local cur = head
	for _, e in ipairs(entries) do
		if cur == "" then
			cur = e
		elseif #cur + #sep + #e > 190 then
			sendChat(cur)
			cur = e
		else
			cur = cur .. (cur == head and " " or sep) .. e
		end
	end
	if cur ~= "" then sendChat(cur) end
end

local httpReq = (syn and syn.request) or (http and http.request) or http_request or request
	or (fluxus and fluxus.request)
local LASTERR = nil

local function httpGet(url)
	task.wait()
	if httpReq then
		local ok, res = pcall(httpReq, { Url = url, Method = "GET", Headers = { Accept = "application/json" } })
		if ok and type(res) == "table" then
			local code = res.StatusCode or res.Status
			if type(res.Body) == "string" and res.Body ~= "" and (code == nil or code == 200) then
				return res.Body
			end
			LASTERR = "HTTP " .. tostring(code)
		else
			LASTERR = "request failed: " .. tostring(res):sub(1, 60)
		end
	end
	local ok, body = pcall(function() return game:HttpGet(url) end)
	if ok and type(body) == "string" and body ~= "" then return body end
	return nil
end

local function decode(body)
	if type(body) ~= "string" then return nil end
	local ok, d = pcall(function() return HttpService:JSONDecode(body) end)
	return ok and d or nil
end

local function metaScan(node, m, depth)
	if type(node) ~= "table" or depth > 3 then return end
	for k, v in pairs(node) do
		if type(k) == "string" then
			local lk = k:lower()
			local tv = type(v)
			if tv == "number" or tv == "string" then
				if lk == "duration" or lk == "durationseconds" or lk == "durationinseconds" or lk == "audiolength" or lk == "timelength" or lk == "length" then
					local n = tonumber(v)
					if not n and tv == "string" then
						local mm, ss = v:match("^(%d+):(%d%d)$")
						if mm then n = tonumber(mm) * 60 + tonumber(ss) end
					end
					if n and n >= 100000 then n = n / 1000 end
					if n and n > 0 and not m.dur then m.dur = n end
				elseif lk == "durationms" or lk == "durationmilliseconds" then
					local n = tonumber(v)
					if n and n > 0 and not m.dur then m.dur = n / 1000 end
				elseif tv == "string" and (lk == "audiotype" or lk == "audiosubtype" or lk == "subtype" or lk == "audiocategory" or lk == "category") then
					local s = v:lower()
					if s:find("effect", 1, true) or s:find("sfx", 1, true) then
						m.sub = "sfx"
					elseif s:find("music", 1, true) or s:find("song", 1, true) then
						m.sub = "music"
					end
				end
			elseif tv == "table" then
				if lk == "tags" or lk == "genres" or lk == "genre" then
					for _, x in pairs(v) do
						local s = type(x) == "table" and (x.name or x.displayName or x.tag) or x
						if type(s) == "string" and #(m.tags or "") < 160 then m.tags = (m.tags or "") .. " " .. s:lower() end
					end
				end
				metaScan(v, m, depth + 1)
			end
		end
	end
end

local function collect(node, out, depth)
	if type(node) ~= "table" or depth > 7 then return end
	local a = type(node.asset) == "table" and node.asset or node
	local id = tonumber(a.id or a.assetId or node.id)
	local nm = a.name or a.title or node.name or node.title
	if id and type(nm) == "string" then
		local cr = node.creator or a.creator
		local author = ""
		if type(cr) == "table" then author = tostring(cr.name or cr.Name or cr.username or "") end
		if author == "" then author = tostring(node.creatorName or a.creatorName or node.creatorTargetName or "") end
		local item = { id = id, name = clean(nm), author = clean(author) }
		local m = {}
		metaScan(node, m, 0)
		if m.dur then item.dur = m.dur end
		if m.sub then item.sub = m.sub end
		if m.tags then item.tags = m.tags end
		out[#out + 1] = item
		return
	end
	for _, v in pairs(node) do collect(v, out, depth + 1) end
end

local function collectIds(node, ids, depth)
	if type(node) ~= "table" or depth > 4 then return end
	if tonumber(node.id) and #ids < 60 then
		ids[#ids + 1] = tonumber(node.id)
		return
	end
	for _, v in pairs(node) do collectIds(v, ids, depth + 1) end
end

local QC = {}
local PLAT = { cur = "audio", custom = {}, down = false, downAt = 0, noted = false }
local W = {}

function PLAT.eff()
	if PLAT.cur == "audio" and PLAT.down and os.clock() - PLAT.downAt > 120 then PLAT.down = false end
	if PLAT.cur == "audio" and PLAT.down then return "catalog" end
	return PLAT.cur
end

function PLAT.key(q)
	return PLAT.eff() .. "|" .. q:lower()
end

local function qcache(q)
	local key = PLAT.key(q)
	local c = QC[key]
	if not c then
		c = { pages = {}, P = nil, tokens = { [0] = "" } }
		QC[key] = c
	end
	return c
end

local function parseResponse(data)
	local out = {}
	collect(data, out, 0)
	if #out == 0 then
		local ids = {}
		collectIds(data, ids, 0)
		if #ids > 0 then
			local d2 = decode(httpGet("https://apis.roblox.com/toolbox-service/v1/items/details?assetIds=" .. table.concat(ids, ",")))
			if d2 then collect(d2, out, 0) end
			if #out == 0 then
				for _, id in ipairs(ids) do out[#out + 1] = { id = id, name = "", author = "" } end
			end
		end
	end
	return out
end

W.ID_PATS = { "library/(%d+)", "rbxassetid://(%d+)", "asset/?%?id=(%d+)", "data%-[%w%-]*id=[\"'](%d+)[\"']", "/audio/(%d+)", "/catalog/(%d+)", "assetid=(%d+)" }
W.JUNK = { copy = true, copied = true, play = true, pause = true, stop = true, share = true, report = true, download = true,
	view = true, preview = true, id = true, ["audio id"] = true, ["suggest tag +"] = true, ["suggest tag"] = true, more = true }

function W.text(s)
	s = tostring(s):gsub("&amp;", "&"):gsub("&#39;", "'"):gsub("&apos;", "'"):gsub("&quot;", '"'):gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&nbsp;", " ")
	return clean(s)
end

function W.good(tx)
	if #tx < 2 or #tx > 80 then return false end
	if not tx:find("%a") then return false end
	local low = tx:lower()
	if W.JUNK[low] or low:find("^listen") then return false end
	return true
end

function W.extract(body)
	body = tostring(body):gsub("<script.-</script>", " "):gsub("<style.-</style>", " "):gsub("<!%-%-.-%-%->", " ")
	local toks = {}
	local i, n = 1, #body
	while i <= n do
		local lt = body:find("<", i, true)
		local stop = lt and (lt - 1) or n
		if stop >= i then
			local tx = W.text(body:sub(i, stop))
			if tx ~= "" then
				if tx:match("^%d+$") and #tx >= 6 and #tx <= 12 then
					toks[#toks + 1] = { k = "idtext", v = tonumber(tx) }
				else
					toks[#toks + 1] = { k = "text", v = tx }
				end
			end
		end
		if not lt then break end
		local gt = body:find(">", lt, true)
		if not gt then break end
		local tag = body:sub(lt, gt)
		for _, pat in ipairs(W.ID_PATS) do
			local id = tag:match(pat)
			if id and #id >= 4 and #id <= 12 then
				toks[#toks + 1] = { k = "idtag", v = tonumber(id) }
				break
			end
		end
		i = gt + 1
	end
	local idxs = {}
	for p, tk in ipairs(toks) do
		if tk.k ~= "text" then idxs[#idxs + 1] = p end
	end
	local out, seen = {}, {}
	for n2, p in ipairs(idxs) do
		local tk = toks[p]
		if not seen[tk.v] and #out < 60 then
			seen[tk.v] = true
			local prev = idxs[n2 - 1] or 0
			local nextp = idxs[n2 + 1] or (#toks + 1)
			local before, after, dur = {}, {}, nil
			for q = prev + 1, p - 1 do
				local x = toks[q]
				if x.k == "text" then
					local mm, ss = x.v:match("^(%d+):(%d%d)$")
					if mm then
						dur = dur or (tonumber(mm) * 60 + tonumber(ss))
					elseif W.good(x.v) then
						before[#before + 1] = x.v
					end
				end
			end
			for q = p + 1, nextp - 1 do
				local x = toks[q]
				if x.k == "text" then
					local mm, ss = x.v:match("^(%d+):(%d%d)$")
					if mm then
						if q <= p + 3 then dur = dur or (tonumber(mm) * 60 + tonumber(ss)) end
					elseif W.good(x.v) and #after < 2 then
						after[#after + 1] = x.v
					end
				end
			end
			local parts = {}
			local nx = toks[p + 1]
			if tk.k == "idtag" and nx and nx.k == "text" and W.good(nx.v) then
				parts[1] = nx.v
			else
				for q = math.max(1, #before - 1), #before do parts[#parts + 1] = before[q] end
				if #parts == 0 then
					for q = 1, #after do parts[#parts + 1] = after[q] end
				end
			end
			local item = { id = tk.v, name = table.concat(parts, " - "):sub(1, 90), author = "" }
			if dur then item.dur = dur end
			out[#out + 1] = item
		end
	end
	return out
end

function W.parse(body)
	local data = decode(body)
	if data then return parseResponse(data) end
	return W.extract(body)
end

function W.url(spec, q, k)
	local url = spec.url
	if not url:find("{q}", 1, true) then return nil end
	local enc = HttpService:UrlEncode(q)
	url = url:gsub("{q}", function() return enc end)
	if url:find("{page}", 1, true) then
		url = url:gsub("{page}", tostring(k + 1))
	elseif k > 0 then
		return false
	end
	return url
end

function W.fetch(spec, q, k)
	local url = W.url(spec, q, k)
	if url == nil then return nil end
	if url == false then return {} end
	local body = httpGet(url)
	if not body then return nil end
	return W.parse(body)
end

function W.count(items, word)
	local n = 0
	for _, it in ipairs(items) do
		if (it.name .. " " .. it.author):lower():find(word, 1, true) then n = n + 1 end
	end
	return n
end

function W.discover(base)
	local sep = base:find("?", 1, true) and "&" or "?"
	local root = base:gsub("/+$", "")
	local tpls = {}
	for _, key in ipairs({ "search", "q", "query", "s", "keyword", "term", "text", "name", "title" }) do
		tpls[#tpls + 1] = base .. sep .. key .. "={q}"
	end
	tpls[#tpls + 1] = root .. "/search/{q}"
	tpls[#tpls + 1] = root .. "/search?q={q}"
	tpls[#tpls + 1] = root .. "/search?query={q}"
	local baseHits = 0
	local body0 = httpGet(base)
	if body0 then baseHits = W.count(W.parse(body0), "love") end
	for _, tpl in ipairs(tpls) do
		local url = tpl:gsub("{q}", "love")
		local body = httpGet(url)
		if body then
			local items = W.parse(body)
			local hits = W.count(items, "love")
			if #items > 0 and hits >= 1 and (hits > baseHits or (hits >= 3 and hits * 2 >= #items)) then
				return tpl, #items
			end
		end
	end
	return nil
end

PLAT.FILE = "BoomboxPlatform.json"

function PLAT.save()
	if not writefile then return end
	local custom = {}
	for name, spec in pairs(PLAT.custom) do custom[name] = { url = spec.url, title = spec.title } end
	pcall(function() writefile(PLAT.FILE, HttpService:JSONEncode({ platform = PLAT.cur, custom = custom })) end)
end

function PLAT.load()
	if not (isfile and readfile) then return end
	pcall(function()
		if not isfile(PLAT.FILE) then return end
		local d = HttpService:JSONDecode(readfile(PLAT.FILE))
		if type(d) ~= "table" then return end
		if type(d.custom) == "table" then
			for name, spec in pairs(d.custom) do
				if type(name) == "string" and type(spec) == "table" and type(spec.url) == "string" then
					PLAT.custom[name] = { url = spec.url, title = tostring(spec.title or name) }
				end
			end
		end
		local cur = d.platform
		if cur == "audio" or cur == "catalog" or (type(cur) == "string" and PLAT.custom[cur]) then PLAT.cur = cur end
	end)
end
PLAT.load()

local function fetchEp(c, q, k, ep)
	local enc = HttpService:UrlEncode(q)
	if ep == 1 then
		local base = "https://apis.roblox.com/toolbox-service/v1/marketplace/3?keyword=" .. enc
		local data = decode(httpGet(base .. "&num=" .. CONFIG.FetchSize .. "&pageNumber=" .. k))
		if not data and c.P == nil and CONFIG.FetchSize > CONFIG.PerPage then
			CONFIG.FetchSize = CONFIG.PerPage
			data = decode(httpGet(base .. "&num=" .. CONFIG.PerPage .. "&pageNumber=" .. k))
		end
		if not data then return nil end
		return parseResponse(data)
	end

	local j = k
	while j > 0 and c.tokens[j] == nil do j = j - 1 end
	if k - j > 30 then return nil end
	local out
	for step = j, k do
		local tok = c.tokens[step]
		if tok == nil then return {} end
		local url = "https://apis.roblox.com/toolbox-service/v2/assets:search?searchCategoryType=Audio&query=" .. enc
			.. "&maxPageSize=30" .. (tok ~= "" and ("&pageToken=" .. HttpService:UrlEncode(tok)) or "")
		local data = decode(httpGet(url))
		if not data then return nil end
		local nxt = data.nextPageToken
		c.tokens[step + 1] = (type(nxt) == "string" and nxt ~= "") and nxt or nil
		out = parseResponse(data)
	end
	return out
end

local function fetchServerPage(c, q, k)
	local p = PLAT.eff()
	if p == "audio" then
		local r = fetchEp(c, q, k, c.ep or 2)
		if r == nil and k == 0 and c.P == nil and not c.ep then
			local r1 = fetchEp(c, q, 0, 1)
			if r1 then
				c.ep = 1
				PLAT.down, PLAT.downAt = true, os.clock()
				if not PLAT.noted then
					PLAT.noted = true
					note("Roblox audio search didn't answer (" .. tostring(LASTERR or "no reply") .. "), so I'm using the Roblox catalog for now. I'll try audio search again in a couple of minutes.")
				end
				return r1
			end
		end
		return r
	elseif p == "catalog" then
		return fetchEp(c, q, k, 1)
	end
	local spec = PLAT.custom[p]
	if not spec then return nil end
	return W.fetch(spec, q, k)
end

local function getItems(q, startIdx, count)
	local c = qcache(q)
	if not c.P then
		local first = fetchServerPage(c, q, 0)
		if not first or #first == 0 then return {} end
		c.pages[0] = first
		c.P = (#first <= CONFIG.PerPage) and CONFIG.PerPage or #first
	end
	local P, out = c.P, {}
	for k = math.floor(startIdx / P), math.floor((startIdx + count - 1) / P) do
		local pg = c.pages[k]
		if not pg then
			pg = fetchServerPage(c, q, k)
			if pg == nil then return out, "far" end
			c.pages[k] = pg
		end
		for i, item in ipairs(pg) do
			local g = k * P + (i - 1)
			if g >= startIdx and g < startIdx + count then out[#out + 1] = { idx = g + 1, item = item } end
		end
		if #pg < P then break end
	end
	return out
end

local function searchFirst(q)
	local got = getItems(q, 0, CONFIG.PerPage)
	local list = {}
	for _, e in ipairs(got) do list[#list + 1] = e.item end
	return list
end

local function norm(s)
	local r = tostring(s or ""):lower()
	r = r:gsub("[%p%c]", " ")
	r = r:gsub("%s+", " ")
	return (r:gsub("^ +", ""):gsub(" +$", ""))
end
local function tokens(s)
	local t = {}
	for w in norm(s):gmatch("%S+") do
		if #w >= 2 then t[#t + 1] = w end
	end
	return t
end
local function overlap(qtok, text)
	if #qtok == 0 then return 0 end
	local n, hit = norm(text), 0
	for _, w in ipairs(qtok) do
		if n:find(w, 1, true) then hit = hit + 1 end
	end
	return hit / #qtok
end

local function score(c, title, author, rank, total)
	local tt, at = tokens(title), tokens(author)
	local nm = norm(c.name)
	local s = overlap(tt, c.name)
	local nt = norm(title)
	if nt ~= "" and nm:find(nt, 1, true) then s = s + 0.5 end
	local ca = norm(c.author)
	if #at > 0 then
		local both = overlap(at, c.author)
		s = s + both
		if both == 0 then s = s + overlap(at, c.name) * 0.3 end
	elseif #ca >= 3 and nt:find(ca, 1, true) then
		s = s + 0.5
	end
	return s + (total - rank) / (total * 100)
end

local SEPS = { " by ", " | ", " - ", " \226\128\147 ", ", " }
local function splitTitleAuthor(s)
	s = trim(s)
	local t, a = s:match("^%(([^%)]+)%)%s*%(([^%)]+)%)$")
	if not t then t, a = s:match("^%[([^%]]+)%]%s*%[([^%]]+)%]$") end
	if t then return trim(t), trim(a) end
	local inner = s:match("^%(([^%)]+)%)$") or s:match("^%[([^%]]+)%]$")
	if inner then s = trim(inner) end
	local low = s:lower()
	for _, sep in ipairs(SEPS) do
		local i, j = low:find(sep, 1, true)
		if i and i > 1 and j < #s then return trim(s:sub(1, i - 1)), trim(s:sub(j + 1)) end
	end
	return s, ""
end

local function looseFind(title, author, want)
	local tries, seen = {}, {}
	local function add(q)
		q = trim(q)
		if q ~= "" and not seen[q:lower()] then
			seen[q:lower()] = true
			tries[#tries + 1] = q
		end
	end
	if author ~= "" then add(title .. " " .. author) end
	add(title)
	local words = {}
	for w in title:gmatch("%S+") do words[#words + 1] = w end
	for n = #words - 1, 1, -1 do add(table.concat(words, " ", 1, n)) end
	local byLen = {}
	for _, w in ipairs(words) do
		if #w >= 3 then byLen[#byLen + 1] = w end
	end
	table.sort(byLen, function(a, b) return #a > #b end)
	for _, w in ipairs(byLen) do add(w) end
	if author ~= "" then add(author) end

	local all, best, bestScore = {}, nil, -1
	local tt = tokens(title)
	for i, q in ipairs(tries) do
		if i > 7 then break end
		local res = searchFirst(q)
		for rank, c in ipairs(res) do
			local sc = score(c, title, author, rank, #res)
			if not all[c.id] or sc > all[c.id].sc then all[c.id] = { c = c, sc = sc } end
			if sc > bestScore then best, bestScore = c, sc end
		end
		if best then
			local authorOk = author == "" or overlap(tokens(author), best.author) > 0.5
			if overlap(tt, best.name) >= 0.99 and authorOk then break end
		end
	end
	local arr = {}
	for _, v in pairs(all) do arr[#arr + 1] = v end
	table.sort(arr, function(a, b) return a.sc > b.sc end)
	local out = {}
	for i = 1, math.min(want or 3, #arr) do out[i] = arr[i].c end
	return out
end

local STOPW = { the = true, a = true, an = true }

local function wordsOf(s)
	local r = tostring(s or ""):lower()
	r = r:gsub("\226\128\153", ""):gsub("['`]", "")
	r = r:gsub("[%p%c]", " ")
	local list, set = {}, {}
	for w in r:gmatch("%S+") do
		list[#list + 1] = w
		set[w] = true
	end
	return list, set
end

local function strictScore(c, qw, aw)
	local nl, nset = wordsOf(c.name)
	local _, aset = wordsOf(c.author)
	local need = {}
	for _, w in ipairs(qw) do
		if not STOPW[w] then need[#need + 1] = w end
	end
	if #need == 0 then need = qw end
	if #need == 0 then return nil end
	local inName = true
	for _, w in ipairs(need) do
		if not nset[w] then
			if not aset[w] then return nil end
			inName = false
		end
	end
	local qn, nn = table.concat(qw, " "), table.concat(nl, " ")
	local sc
	if nn == qn then
		sc = 100
	elseif inName and (" " .. nn .. " "):find(" " .. qn .. " ", 1, true) then
		sc = 80
	elseif inName then
		sc = 60
	else
		sc = 50
	end
	local frac = 1
	if #aw > 0 then
		local hit = 0
		for _, w in ipairs(aw) do
			if aset[w] then
				hit = hit + 1
			elseif nset[w] then
				hit = hit + 0.8
			end
		end
		frac = hit / #aw
		sc = sc + 25 * frac
	end
	local extra = #nl - #qw
	if extra > 0 then sc = sc - math.min(extra, 20) * 0.4 end
	return sc, frac
end

local K = { dur = {}, sfx = {}, long = {} }
K.token = { sfx = "sfx", sfxs = "sfx", soundeffect = "sfx", soundeffects = "sfx", long = "long", song = "song", songs = "song", music = "song", short = "short" }
K.name = { sfx = "sfx", song = "song", long = "long audio", short = "short audio" }
K.sfxPool = { "explosion", "click", "whoosh", "punch", "laser", "door", "footsteps", "scream", "beep", "alarm", "water splash",
	"glass break", "gunshot", "thunder", "coin", "jump", "bell", "pop", "siren", "oof" }
K.longPool = { "1 hour", "mix", "extended", "ambience", "nonstop", "compilation", "full album", "10 hours" }
for w in ("sfx sfxs fx soundfx"):gmatch("%S+") do K.sfx[w] = true end
for w in ("hour hours hr hrs extended mix compilation nonstop marathon playlist ambience megamix"):gmatch("%S+") do K.long[w] = true end

function K.has(c, set)
	local low = ((c.name or "") .. " " .. (c.tags or "")):lower()
	local _, words = wordsOf(low)
	for w in pairs(words) do
		if set[w] then return true end
	end
	if set == K.sfx and low:find("sound effect", 1, true) then return true end
	if set == K.long and (low:find("full album", 1, true) or low:find("non stop", 1, true)) then return true end
	return false
end

function K.of(c)
	local d = K.dur[c.id] or c.dur
	local sfxw = K.has(c, K.sfx)
	if d and d > 0 then
		if d <= CONFIG.SfxMax then return "sfx", d end
		if d >= CONFIG.LongMin then return "long", d end
		if c.sub == "sfx" or (sfxw and d < CONFIG.ShortMax) then return "sfx", d end
		if d < CONFIG.ShortMax then return "short", d end
		return "song", d
	end
	if c.sub == "sfx" then return "sfx" end
	if c.sub == "music" then return "song" end
	return nil
end

function K.match(c, want)
	if not want then return "yes" end
	local k = K.of(c)
	if k then
		if want == "short" then return (k == "short" or k == "sfx") and "yes" or "no" end
		return (k == want) and "yes" or "no"
	end
	local sfxw = K.has(c, K.sfx)
	if want == "sfx" then return sfxw and "yes" or "maybe" end
	if want == "song" then
		if sfxw then return "no" end
		if K.has(c, K.long) then return "maybe" end
		return "yes"
	end
	if want == "short" and sfxw then return "yes" end
	return "maybe"
end

function K.fmt(d)
	d = math.floor(d + 0.5)
	if d >= 3600 then
		return string.format("%d:%02d:%02d", math.floor(d / 3600), math.floor(d % 3600 / 60), d % 60)
	end
	return string.format("%d:%02d", math.floor(d / 60), d % 60)
end

function K.tag(c)
	local k, d = K.of(c)
	if not k then return "" end
	return " [" .. k .. (d and (" " .. K.fmt(d)) or "") .. "]"
end

local ContentProvider = nil
pcall(function() ContentProvider = game:GetService("ContentProvider") end)

function K.probe(id)
	if K.dur[id] then return K.dur[id] end
	if not ContentProvider then return nil end
	local len = nil
	pcall(function()
		local s = Instance.new("Sound")
		s.SoundId = "rbxassetid://" .. id
		s.Volume = 0
		ContentProvider:PreloadAsync({ s })
		len = tonumber(s.TimeLength)
		pcall(function() s:Destroy() end)
	end)
	if len and len > 0 then
		K.dur[id] = len
		return len
	end
	return nil
end

function K.batch(items)
	local pending = 0
	for _, it in ipairs(items) do
		if not K.dur[it.id] then
			pending = pending + 1
			task.spawn(function()
				pcall(K.probe, it.id)
				pending = pending - 1
			end)
		end
	end
	local t0 = os.clock()
	while pending > 0 and os.clock() - t0 < 5 and not gone do task.wait(0.1) end
end

function K.split(text, allowSingle)
	text = trim(text)
	local words = {}
	for w in text:gmatch("%S+") do words[#words + 1] = w end
	local n = #words
	local function tok(w) return (w:lower():gsub("[%[%]%(%)]", "")) end
	if n >= 2 then
		local two = tok(words[n - 1]) .. tok(words[n])
		if K.token[two] and (n > 2 or allowSingle) then
			return table.concat(words, " ", 1, n - 2), K.token[two]
		end
	end
	if n >= 1 then
		local k = K.token[tok(words[n])]
		if k and (n > 1 or allowSingle) then
			return table.concat(words, " ", 1, n - 1), k
		end
	end
	return text, nil
end

local function strictFind(title, author, want, kind)
	want = want or 3
	local qw = wordsOf(title)
	if #qw == 0 then return {} end
	local aw = wordsOf(author)
	local variants, seenV = {}, {}
	local function addV(q)
		q = trim(q)
		if q ~= "" and not seenV[q:lower()] then
			seenV[q:lower()] = true
			variants[#variants + 1] = q
		end
	end
	if author ~= "" then addV(title .. " " .. author) end
	addV(title)
	addV(table.concat(qw, " "))
	local byLen = {}
	for _, w in ipairs(qw) do
		if #w >= 3 and not STOPW[w] then byLen[#byLen + 1] = w end
	end
	table.sort(byLen, function(a, b)
		if #a ~= #b then return #a > #b end
		return a < b
	end)
	for i = 1, math.min(2, #byLen) do addV(byLen[i]) end
	if author ~= "" then addV(author) end
	if kind == "sfx" or kind == "short" then
		addV(title .. " sfx")
		addV(title .. " sound effect")
	elseif kind == "long" then
		addV(title .. " extended")
		addV(title .. " 1 hour")
	end

	local found, order = {}, {}
	local authorHit = false
	for _, q in ipairs(variants) do
		local idx, exact, strong = 0, 0, 0
		while idx < CONFIG.StrictDepth do
			local got = getItems(q, idx, CONFIG.PerPage)
			if #got == 0 then break end
			for _, e in ipairs(got) do
				local sc, frac = strictScore(e.item, qw, aw)
				local m = sc and K.match(e.item, kind) or "no"
				if sc and m ~= "no" then
					if frac >= 0.99 then authorHit = true end
					sc = sc + 0.1 * math.max(0, 1 - e.idx / 400)
					local prev = found[e.item.id]
					if not prev then
						found[e.item.id] = { c = e.item, sc = sc, m = m }
						order[#order + 1] = e.item.id
						if m == "yes" then
							if sc >= 95 then exact = exact + 1 end
							if sc >= 75 then strong = strong + 1 end
						end
					elseif sc > prev.sc then
						prev.sc = sc
					end
				end
			end
			idx = idx + CONFIG.PerPage
			if #got < CONFIG.PerPage or exact >= want then break end
			if exact >= 1 and #order >= want and (#aw == 0 or authorHit) then break end
		end
		if strong >= 1 then break end
	end

	local arr = {}
	for _, id in ipairs(order) do arr[#arr + 1] = found[id] end
	local function sortArr()
		table.sort(arr, function(a, b)
			local ra, rb = a.sc + (a.m == "yes" and 5 or 0), b.sc + (b.m == "yes" and 5 or 0)
			if ra ~= rb then return ra > rb end
			return a.c.id < b.c.id
		end)
	end
	sortArr()
	if kind then
		local need = {}
		for i = 1, math.min(#arr, 8) do
			if arr[i].m == "maybe" then need[#need + 1] = arr[i].c end
		end
		if #need > 0 then
			K.batch(need)
			local keep = {}
			for _, a in ipairs(arr) do
				a.m = K.match(a.c, kind)
				if a.m ~= "no" then keep[#keep + 1] = a end
			end
			arr = keep
			sortArr()
		end
	end
	local out = {}
	for i = 1, math.min(want, #arr) do out[i] = arr[i].c end
	return out, arr[1] and arr[1].sc or nil
end

local function findAudio(title, author, want, kind)
	local res, top = strictFind(title, author, want or 3, kind)
	if #res > 0 or CONFIG.Strict then return res, top end
	local loose = looseFind(title, author, kind and 9 or want)
	if kind then
		local keep = {}
		for _, c in ipairs(loose) do
			if K.match(c, kind) ~= "no" and #keep < (want or 3) then keep[#keep + 1] = c end
		end
		loose = keep
		if #loose == 0 then loose = looseFind(title, author, want) end
	end
	return loose
end

local SL = {}
local function strictList(query, need)
	local key = PLAT.key(query)
	local s = SL[key]
	if not s then
		local title, author = splitTitleAuthor(query)
		s = { items = {}, scanned = 0, done = false, seen = {} }
		s.qw = wordsOf(title)
		s.aw = wordsOf(author)
		local tries = {}
		if author ~= "" then tries[#tries + 1] = trim(title .. " " .. author) end
		tries[#tries + 1] = trim(title)
		local longest = nil
		for _, w in ipairs(s.qw) do
			if #w >= 3 and not STOPW[w] and (not longest or #w > #longest) then longest = w end
		end
		if longest then tries[#tries + 1] = longest end
		for _, tq in ipairs(tries) do
			if tq ~= "" and #getItems(tq, 0, 1) > 0 then
				s.q = tq
				break
			end
		end
		if not s.q then
			s.q = tries[1]
			s.done = true
		end
		SL[key] = s
	end
	local first = s.scanned == 0
	while not s.done and s.scanned < CONFIG.StrictScanMax and (first or #s.items < need) do
		local chunkEnd = s.scanned + (first and CONFIG.StrictDepth or 30)
		local add = {}
		while s.scanned < chunkEnd do
			local got = getItems(s.q, s.scanned, CONFIG.PerPage)
			if #got == 0 then
				s.done = true
				break
			end
			for _, e in ipairs(got) do
				local sc = strictScore(e.item, s.qw, s.aw)
				if sc and not s.seen[e.item.id] then
					s.seen[e.item.id] = true
					add[#add + 1] = { item = e.item, sc = sc, idx = e.idx }
				end
			end
			s.scanned = s.scanned + CONFIG.PerPage
			if #got < CONFIG.PerPage then
				s.done = true
				break
			end
		end
		table.sort(add, function(a, b)
			if a.sc ~= b.sc then return a.sc > b.sc end
			return a.idx < b.idx
		end)
		for _, a in ipairs(add) do s.items[#s.items + 1] = a.item end
		first = false
	end
	return s
end

local GENRES = { "rock", "pop", "hip hop", "rap", "electronic", "edm", "house", "techno", "trance", "dubstep",
	"drum and bass", "trap", "lofi", "phonk", "jazz", "blues", "classical", "orchestral", "piano", "ambient",
	"cinematic", "soundtrack", "metal", "punk", "indie", "folk", "country", "reggae", "funk", "disco", "rnb",
	"soul", "synthwave", "vaporwave", "chiptune", "8-bit", "k-pop", "anime", "meme", "horror", "epic", "chill",
	"remix", "nightcore", "christmas", "latin", "acoustic", "gaming" }
local GENRE_ALIAS = { hiphop = "hip hop", ["hip-hop"] = "hip hop", ["r&b"] = "rnb", ["r and b"] = "rnb",
	dnb = "drum and bass", kpop = "k-pop", ["8bit"] = "8-bit", ["lo-fi"] = "lofi", ["lo fi"] = "lofi",
	electro = "electronic", edm = "edm", classic = "classical", game = "gaming", videogame = "gaming",
	scary = "horror", ["heavy metal"] = "metal", trapmusic = "trap" }
local GENRE_SET = {}
for _, g in ipairs(GENRES) do GENRE_SET[g] = true end

local function resolveGenre(s)
	s = norm(s):gsub("^the ", "")
	local raw = trim(s)
	if GENRE_ALIAS[raw] then raw = GENRE_ALIAS[raw] end
	if GENRE_SET[raw] then return raw end
	local spaced = raw:gsub("%-", " ")
	if GENRE_SET[spaced] then return spaced end
	return nil
end

local function randomFor(keyword)
	local first = getItems(keyword, 0, 1)
	if #first == 0 then return nil end
	local c = QC[PLAT.key(keyword)]
	local P = c and c.P or CONFIG.PerPage
	local eff = PLAT.eff()
	local maxPage = (eff == "audio") and 5 or ((eff == "catalog") and 20 or 0)
	local g = math.random(0, maxPage) * P + math.random(0, P - 1)
	local got = getItems(keyword, g, 1)
	if #got == 0 then got = getItems(keyword, math.random(0, P - 1), 1) end
	return (got[1] and got[1].item) or first[1].item
end

function K.random(keyword, kind)
	local queries = {}
	if keyword then
		if kind == "long" then
			queries = { keyword .. " mix", keyword .. " 1 hour", keyword .. " extended", keyword }
		elseif kind == "sfx" or kind == "short" then
			queries = { keyword .. " sfx", keyword }
		else
			queries = { keyword }
		end
	else
		local src = GENRES
		if kind == "sfx" or kind == "short" then
			src = K.sfxPool
		elseif kind == "long" then
			src = K.longPool
		end
		for i, g in ipairs(src) do queries[i] = g end
		for i = #queries, 2, -1 do
			local j = math.random(i)
			queries[i], queries[j] = queries[j], queries[i]
		end
	end
	local got, seen, tries, qi = {}, {}, 0, 0
	local goal = kind and 6 or 3
	while #got < goal and tries < 10 and not gone do
		tries = tries + 1
		qi = qi % #queries + 1
		local c = randomFor(queries[qi])
		if c and not seen[c.id] then
			seen[c.id] = true
			if K.match(c, kind) ~= "no" then got[#got + 1] = c end
		end
	end
	local maybes = {}
	for _, c in ipairs(got) do
		if K.match(c, kind) == "maybe" then maybes[#maybes + 1] = c end
	end
	if #maybes > 0 then K.batch(maybes) end
	local yes, rest = {}, {}
	for _, c in ipairs(got) do
		local m = K.match(c, kind)
		if m == "yes" then
			yes[#yes + 1] = c
		elseif m == "maybe" then
			rest[#rest + 1] = c
		end
	end
	for _, c in ipairs(rest) do yes[#yes + 1] = c end
	local out = {}
	for i = 1, math.min(3, #yes) do out[i] = yes[i] end
	return out
end

local function getChar() return LocalPlayer.Character end
local function getHum()
	local c = getChar()
	return c and c:FindFirstChildOfClass("Humanoid")
end

local function findBoombox()
	local function look(container, pat)
		if not container then return nil end
		for _, t in ipairs(container:GetChildren()) do
			if t:IsA("Tool") and t.Name:lower():find(pat) then return t end
		end
	end
	local bp = LocalPlayer:FindFirstChildOfClass("Backpack")
	for _, pat in ipairs({ "boom", "jukebox", "radio", "stereo", "music" }) do
		local t = look(getChar(), pat) or look(bp, pat)
		if t then return t end
	end
	return nil
end

local function equipTool(tool)
	local hum = getHum()
	if not hum then return false end
	UI.watch(tool)
	if tool.Parent == getChar() then return true end
	if UI.fly then
		pcall(function() tool.Parent = getChar() end)
		return true
	end
	pcall(function() hum:EquipTool(tool) end)
	return true
end

local SC = { map = {}, n = 0, deep = {}, homes = {} }
local SoundService = nil
pcall(function() SoundService = game:GetService("SoundService") end)

local function soundMatches(d, needle)
	return d.IsPlaying and tostring(d.SoundId):find(needle, 1, true) ~= nil
end

local function scanRoot(root, needle)
	local ok, found = pcall(function()
		if root:IsA("Sound") then
			if soundMatches(root, needle) then return root end
			return nil
		end
		for _, d in ipairs(root:GetDescendants()) do
			if d:IsA("Sound") and soundMatches(d, needle) then return d end
		end
		return nil
	end)
	if ok then return found end
	return nil
end

local function deepFind(needle)
	local now = os.clock()
	if SC.deep[needle] and now - SC.deep[needle] < 8 then return nil end
	SC.deep[needle] = now
	local mine = getChar()
	local roots = {}
	local ok, kids = pcall(function() return Workspace:GetChildren() end)
	if ok then
		for _, k in ipairs(kids) do
			local skip = (k == mine) or k:IsA("Terrain") or k:IsA("Camera")
			if not skip then
				local okp, owner = pcall(function() return Players:GetPlayerFromCharacter(k) end)
				if okp and owner then skip = true end
			end
			if not skip then roots[#roots + 1] = k end
		end
	end
	if SoundService then roots[#roots + 1] = SoundService end
	local started = os.clock()
	for i, root in ipairs(roots) do
		local s = scanRoot(root, needle)
		if s then return s end
		if i % 4 == 0 then
			task.wait()
			if os.clock() - started > 3 then break end
		end
	end
	return nil
end

local function homeScan(needle)
	for _, home in ipairs(SC.homes) do
		if home == Workspace or home.Parent then
			local ok, kids = pcall(function() return home:GetChildren() end)
			if ok then
				for _, d in ipairs(kids) do
					local isMatch = false
					pcall(function() isMatch = d:IsA("Sound") and soundMatches(d, needle) end)
					if isMatch then return d end
				end
			end
		end
	end
	return nil
end

local function rememberHome(snd)
	local par = nil
	pcall(function() par = snd.Parent end)
	if not par then return end
	for _, h in ipairs(SC.homes) do
		if h == par then return end
	end
	if #SC.homes >= 4 then table.remove(SC.homes, 1) end
	SC.homes[#SC.homes + 1] = par
end

local function findSound(id, tool, deep)
	local needle = tostring(id)
	local cached = SC.map[needle]
	if cached then
		local ok, good = pcall(function() return cached.Parent ~= nil and soundMatches(cached, needle) end)
		if ok and good then return cached end
		SC.map[needle] = nil
	end
	local found = nil
	for _, root in ipairs({ tool or false, getChar() or false }) do
		if root and not found then found = scanRoot(root, needle) end
	end
	if not found then found = homeScan(needle) end
	if not found and deep then found = deepFind(needle) end
	if found then
		rememberHome(found)
		if SC.n >= 30 then SC.map, SC.n = {}, 0 end
		SC.map[needle] = found
		SC.n = SC.n + 1
	end
	return found
end

local function soundPlaying(id, tool, deep)
	return findSound(id, tool, deep) ~= nil
end

local function fireAll(tool, ...)
	local args, n = { ... }, 0
	for _, d in ipairs(tool:GetDescendants()) do
		if d:IsA("RemoteEvent") then
			n = n + 1
			pcall(function() d:FireServer(unpack(args)) end)
		end
	end
	return n
end

local function nameLooksLikeBoombox(node, stop)
	local a = node
	while a and a ~= stop do
		local n = a.Name:lower()
		if n:find("boom") or n:find("music") or n:find("radio") then return true end
		a = a.Parent
	end
	return false
end

local function guiPlay(id)
	local pg = LocalPlayer:FindFirstChildOfClass("PlayerGui")
	if not pg then return false end
	local did = false
	pcall(function()
		for _, sg in ipairs(pg:GetChildren()) do
			if sg:IsA("ScreenGui") and not OWN_GUI[sg.Name] then
				local buttons, hit = {}, false
				local desc = sg:GetDescendants()
				for _, d in ipairs(desc) do
					if d:IsA("TextBox") then
						if nameLooksLikeBoombox(d, pg) then
							d.Text = tostring(id)
							hit = true
						end
					elseif d:IsA("TextButton") or d:IsA("ImageButton") then
						buttons[#buttons + 1] = d
					end
				end
				if hit then
					for _, b in ipairs(buttons) do
						local nm = (b.Name .. " " .. (b:IsA("TextButton") and b.Text or "")):lower()
						if nm:find("play") and not nm:find("stop") then
							if firesignal then
								pcall(firesignal, b.MouseButton1Click)
								pcall(firesignal, b.Activated)
							end
							did = true
						end
					end
				end
				if #desc > 800 then task.wait() end
			end
		end
	end)
	return did
end

local function boomSounds(tool, id)
	local list, seen = {}, {}
	local function take(s)
		if s and not seen[s] then
			seen[s] = true
			list[#list + 1] = s
		end
	end
	if tool then
		pcall(function()
			for _, d in ipairs(tool:GetDescendants()) do
				if d:IsA("Sound") then take(d) end
			end
		end)
	end
	if id and tool then take(findSound(id, tool)) end
	return list
end

local function applyVolume(tool, id)
	local v = CONFIG.Volume
	if v == nil then return 0 end
	local n = 0
	for _, snd in ipairs(boomSounds(tool, id)) do
		if pcall(function() snd.Volume = v end) then n = n + 1 end
		if v > 1 then
			pcall(function()
				snd.RollOffMinDistance = math.max(snd.RollOffMinDistance, v * 100)
				snd.RollOffMaxDistance = math.max(snd.RollOffMaxDistance, v * 1000)
			end)
		end
	end
	return n
end

local function sendVolume(tool, v)
	if not tool then return end
	fireAll(tool, "Volume", v)
	fireAll(tool, "SetVolume", v)
	fireAll(tool, "ChangeVolume", v)
end

local goodForm = nil
local function playAudio(tool, c, quick)
	local id = c.id
	local forms = {
		function() return fireAll(tool, "PlaySong", id) end,
		function() return fireAll(tool, "Play", id) end,
		function() return fireAll(tool, "play", id) end,
		function() return fireAll(tool, "PlaySong", "rbxassetid://" .. id) end,
		function() return fireAll(tool, id) end,
		function() return guiPlay(id) and 1 or 0 end,
	}
	local order = {}
	if goodForm then order[1] = goodForm end
	for i = 1, #forms do
		if i ~= goodForm then order[#order + 1] = i end
	end
	local deepTried = false
	SC.deep[tostring(id)] = nil
	for n, i in ipairs(order) do
		if quick and n > 2 then break end
		local sent = forms[i]()
		if sent and sent > 0 then
			for pollNo = 1, quick and 6 or 8 do
				task.wait(0.35)
				local deep = (not deepTried) and pollNo >= 4
				if deep then deepTried = true end
				if soundPlaying(id, tool, deep) then
					goodForm = i
					if CONFIG.Volume ~= nil then
						applyVolume(tool, id)
						task.spawn(function()
							task.wait(1.5)
							applyVolume(tool, id)
						end)
					end
					return true
				end
			end
		end
	end
	return false
end

local function stopBoombox()
	local tool = findBoombox()
	if not tool then return end
	fireAll(tool, "Stop")
	fireAll(tool, "StopSong")
	local hum = getHum()
	if hum and not UI.fly then pcall(function() hum:UnequipTools() end) end
end

local function label(c)
	local l = c.name ~= "" and c.name or ("audio " .. c.id)
	l = l:sub(1, 60)
	if c.author ~= "" then l = l .. " by " .. c.author:sub(1, 25) end
	return l
end

local CMD_LINES = {
	"Boombox commands (1/6): /play <title> [author] [sfx|long|song] | /play <audio id> | /play random [genre] [sfx|long|song] | /play pick <number> | /play stop",
	"Boombox commands (2/6): /skip | /queue | /queue remove <number|title|last> | /queue clear | /volume <0-10>",
	"Boombox commands (3/6): /audio search <words> [page 1-1000] | /audio next | /audio prev | /audio id <number> | /audio grab id <title> [author]",
	"Boombox commands (4/6): /album create <name> | /album load <name> | /album add <audio> <album> | /album delete <name> | /album audio remove <audio> <album>",
	"Boombox commands (5/6): /search platform [name] | /search platform add <name> <url> | /album list [name] | /album skip | /album stop",
	"Boombox commands (6/6): /audio help [command] | /cmds | owner only: /whitelist <player> | /blacklist <player> | /audio access everyone|friends|me | /audio strict on|off",
}
local HELP = {
	play = "/play <title> [author] [sfx|long|song] - queues that audio (exact match). The type word is optional and narrows the search. /play <audio id> queues that exact id.",
	random = "/play random [genre] [sfx|long|song] - queues a random audio. Genre is optional (rock, lofi, jazz...). With sfx or long any word works: /play random explosion sfx.",
	pick = "/play pick <number> - queues that number from your last /audio search.",
	stop = "/play stop - stops the boombox and clears the whole queue.",
	skip = "/skip - skips the audio that is playing and plays the next one in the queue. If the queue is empty it stops the boombox.",
	queue = "/queue - shows what is queued. /queue remove <number|title|last> takes one out (yours; the owner can remove any). /queue clear removes all of yours.",
	types = "sfx = sound effects (about 10 s or less), short = under 45 s, song = normal music, long = 5 min or more. Put one last: /play explosion sfx. I check the real length when it plays.",
	platform = "/search platform [name] - shows or changes where I search: audio (Roblox audio search, the default), catalog, or a site added with /search platform add <name> <url with {q}>. Saved. Owner only.",
	search = "/audio search <words> - lists up to 10 audios in chat. /audio search <page 1-1000> shows another page of the same search. /audio next and /audio prev flip pages.",
	id = "/audio id <number> - sends the audio id for that number from your last /audio search (it is also copied to your clipboard).",
	grab = "/audio grab id <title> [author] - sends the id of that audio, or 'audio may have been removed/banned' if there is no exact match.",
	cmds = "/cmds - lists every command in chat.",
	whitelist = "/whitelist <player> - lets that player use my boombox commands, even when access is set to friends or me. /whitelist alone shows both lists. Owner only.",
	blacklist = "/blacklist <player> - takes away that player's access, even when access is set to everyone. /whitelist <player> gives it back. Owner only.",
	access = "/audio access everyone|friends|me - who may use the commands. /whitelist and /blacklist override it for single players. Owner only.",
	volume = "/volume <0-10> - sets how loud the boombox plays (up, down, max, mute or 50% also work). Louder also widens how far it can be heard. /volume alone shows the current level.",
	strict = "/audio strict on|off - on (default): only audios that really contain the words you typed. off: if nothing matches I play the closest audio. Owner only.",
	album = "/album create <name> | load <name> | add <audio> <album> | delete <name> | audio remove <audio> <album> | list [name] | skip | stop. Albums are personal: only their creator can use them.",
	create = "/album create <name> - makes your own album (up to 10, name up to 24 characters). Only you can use it. Example: /album create chill",
	load = "/album load <name> - queues every audio of your album in order. /album skip jumps to the next one and /album stop removes the album from the queue.",
	add = "/album add <audio> <album> - adds an audio to your album. <audio> = title [author], an audio id, a number from /audio search, or now. Example: /album add sweden c418 chill",
	delete = "/album delete <name> - deletes your album and everything in it.",
	remove = "/album audio remove <audio> <album> - removes one audio from your album. <audio> = its number in /album list, its id or part of its title.",
	list = "/album list - shows your albums. /album list <name> [page] - shows the audios in that album with their numbers.",
	albumskip = "/album skip - jumps to the next audio of the album that is playing. /album stop - removes the album from the queue. Only who loaded it or the owner.",
	help = "/audio help [command] - explains a command, for example /audio help search. Without a command it lists them all.",
}
local HELP_ALIAS = { next = "search", prev = "search", previous = "search", page = "search", commands = "cmds",
	genre = "random", genres = "random", audio = "search", boombox = "play", ["audio id"] = "id",
	allow = "whitelist", block = "blacklist", ban = "blacklist", wl = "whitelist", bl = "blacklist",
	albums = "album", playlist = "album", playlists = "album", exact = "strict", vol = "volume", loud = "volume", loudness = "volume",
	q = "queue", queued = "queue", sfx = "types", long = "types", song = "types", short = "types", type = "types", kind = "types",
	platforms = "platform", source = "platform", site = "platform", sites = "platform" }
local ALBUM_SUB = { stop = "albumskip", skip = "albumskip", new = "create", make = "create", del = "delete", destroy = "delete", rm = "remove",
	audio = "remove", show = "list", view = "list", play = "load" }

local function showCmds()
	for _, line in ipairs(CMD_LINES) do sendChat(line) end
end

local function showHelp(name)
	name = trim(name:lower():gsub("^/", ""):gsub("^audio%s+", ""):gsub("^play%s+", ""))
	if name == "" then
		showCmds()
		return
	end
	local first, second = name:match("^(%S+)%s*(%S*)")
	name = first or ""
	if name == "search" and second == "platform" then name = "platform" end
	if name == "album" and second ~= "" then
		name = ALBUM_SUB[second] or second
		if not HELP[name] then name = "album" end
	end
	name = HELP_ALIAS[name] or name
	if HELP[name] then
		sendChat("Help: " .. HELP[name])
	else
		sendChat("I don't know a command called " .. name:sub(1, 30) .. ". Try /cmds for the list.")
	end
end

local playGen = 0
local Q = { items = {}, cur = nil, running = false, skip = false, endNote = nil }
local LASTS = {}
local function lastOf(uid)
	local l = LASTS[uid]
	if not l then
		l = { query = nil, page = 1, byIdx = {} }
		LASTS[uid] = l
	end
	return l
end

local function hint(who, text)
	if who == LocalPlayer then
		note(text)
	else
		sendChat("Usage: " .. text)
	end
end

local function playFirstThatWorks(tool, cands, gen, quickAll)
	equipTool(tool)
	task.wait(0.5)
	for i, c in ipairs(cands) do
		if gen ~= playGen then return nil end
		if playAudio(tool, c, quickAll or i > 1) then return c end
	end
	return nil
end

local NOW = nil

local function noneFound(strictNote, kind)
	if kind then
		sendChat("No " .. K.name[kind] .. " matched that - try it without '" .. kind .. "'.")
	else
		sendChat(NONE_MSG)
	end
	if strictNote and CONFIG.Strict then
		note("Strict search found no exact match. /audio strict off lets me play the closest audio instead.")
	end
	if LASTERR then problem("The audio search request failed (" .. LASTERR .. "). If every search says this, your executor can't reach Roblox's audio search.") end
end

local function doPlay(rest, who)
	who = who or LocalPlayer
	local L = lastOf(who.UserId)
	rest = trim(rest)
	local low = rest:lower()
	if rest == "" then
		hint(who, "/play <title> [author] [sfx|long|song]  |  /play random [genre] [sfx|long|song]  |  /play pick <number>  |  /play stop  |  /skip  |  /queue  |  /cmds")
		return
	end
	if low == "stop" then
		Q.stop()
		return
	end
	local gen0 = playGen
	local tool = findBoombox()
	if not tool then
		sendChat("I need boombox.")
		return
	end
	LASTERR = nil
	local cands, kind = {}, nil

	local pick = low:match("^pick%s+(%d+)$")
	local small = rest:match("^(%d%d?%d?%d?)$")
	if not pick and small and L.byIdx[tonumber(small)] then pick = small end
	local direct = rest:match("^(%d%d%d%d%d+)$")
	if pick then
		local item = L.byIdx[tonumber(pick)]
		if not item then
			sendChat("I don't have audio #" .. pick .. " from the last search.")
			return
		end
		cands = { item }
	elseif direct then
		cands = { { id = tonumber(direct), name = "audio " .. direct, author = "" } }
	elseif low == "random" or low:match("^random%s") then
		local gtext
		gtext, kind = K.split(trim(low:sub(7)), true)
		local keyword = nil
		if gtext ~= "" then
			keyword = resolveGenre(gtext)
			if not keyword then
				if kind == "sfx" or kind == "long" or kind == "short" then
					keyword = gtext
				else
					sendChat("genre doesn't exist!")
					sendList("Genres:", GENRES, ", ")
					return
				end
			end
		end
		cands = K.random(keyword, kind)
		if #cands == 0 then
			noneFound(false, kind)
			return
		end
	else
		local body, k = K.split(rest, false)
		local title, author = splitTitleAuthor(body)
		kind = k
		if kind then
			local wt, wa = splitTitleAuthor(rest)
			local whole, top = strictFind(wt, wa, 3)
			if #whole > 0 and top and top >= 95 then
				cands, kind = whole, nil
			end
		end
		if #cands == 0 then
			cands = findAudio(title, author, 3, kind)
			if #cands == 0 then
				noneFound(true, kind)
				return
			end
		end
	end
	if gen0 ~= playGen then return end
	Q.add({ cands = cands, who = who, kind = kind })
end

local function copyId(id, who)
	if who == LocalPlayer and setclipboard then pcall(setclipboard, tostring(id)) end
end

local function listPage(L, query, page)
	local startIdx = (page - 1) * CONFIG.PerPage
	local got, why
	if CONFIG.Strict then
		local s = strictList(query, page * CONFIG.PerPage)
		got = {}
		for i = startIdx + 1, math.min(#s.items, startIdx + CONFIG.PerPage) do
			got[#got + 1] = { idx = i, item = s.items[i] }
		end
		if #got == 0 then
			if page == 1 then
				sendChat("No exact matches for that search. (Strict search is on; the owner can use /audio strict off to see every result.)")
				if LASTERR then problem("The audio search request failed (" .. LASTERR .. ").") end
			else
				sendChat("No more exact matches - that search ends before page " .. page .. ".")
			end
			return
		end
	else
		got, why = getItems(query, startIdx, CONFIG.PerPage)
	end
	if #got == 0 then
		if page == 1 then
			sendChat("No audios found for that search.")
			if LASTERR then problem("The audio search request failed (" .. LASTERR .. ").") end
		elseif why == "far" then
			sendChat("That page is too far for me to jump to - try a lower page number.")
		else
			sendChat("No more results - that search ends before page " .. page .. ".")
		end
		return
	end
	if L.query ~= query then L.byIdx = {} end
	L.query, L.page, L.strict = query, page, CONFIG.Strict
	local entries = {}
	for _, e in ipairs(got) do
		L.byIdx[e.idx] = e.item
		local it = e.item
		local nm = it.name ~= "" and it.name or ("audio " .. it.id)
		entries[#entries + 1] = e.idx .. ". " .. nm:sub(1, 45) .. (it.author ~= "" and (" - " .. it.author:sub(1, 20)) or "")
	end
	sendList("Audio search \"" .. query:sub(1, 40) .. "\" page " .. page .. ":", entries, " | ")
	sendChat("Use /audio search <page> for more, /audio id <number> for an id, /play pick <number> to play one.")
end

local function doAudio(rest, who)
	who = who or LocalPlayer
	local L = lastOf(who.UserId)
	rest = trim(rest)
	local sub, arg = rest:match("^(%a+)%s*(.*)$")
	sub = sub and sub:lower() or ""
	arg = trim(arg)
	LASTERR = nil

	if sub == "search" or sub == "next" or sub == "prev" or sub == "previous" then
		local query, page = nil, 1
		if sub == "next" or sub == "prev" or sub == "previous" then
			if not L.query then
				hint(who, "Search for something first: /audio search <words>")
				return
			end
			query, page = L.query, L.page + (sub == "next" and 1 or -1)
		elseif arg:match("^%d+$") and L.query then
			query, page = L.query, tonumber(arg)
		else
			local q, p = arg:match("^(.-)%s+page%s+(%d+)$")
			if q and q ~= "" then
				query, page = q, tonumber(p)
			else
				query = arg
			end
		end
		if not query or query == "" then
			hint(who, "/audio search <words>   then   /audio search <page 1-1000>")
			return
		end
		if page < 1 or page > CONFIG.MaxPage then
			sendChat("Pages go from 1 to " .. CONFIG.MaxPage .. ".")
			return
		end
		listPage(L, query, page)

	elseif sub == "id" then
		local n = tonumber(arg:match("^#?(%d+)$") or "")
		if not n then
			hint(who, "/audio id <number from your last /audio search>")
			return
		end
		local item = L.byIdx[n]
		if not item and L.query and not L.strict then
			getItems(L.query, math.floor((n - 1) / CONFIG.PerPage) * CONFIG.PerPage, CONFIG.PerPage)
			local c = QC[PLAT.key(L.query)]
			if c and c.P then
				local k = math.floor((n - 1) / c.P)
				local pg = c.pages[k]
				if pg then item = pg[(n - 1) - k * c.P + 1] end
			end
		end
		if not item then
			sendChat("I don't have audio #" .. n .. " from the last search.")
			return
		end
		copyId(item.id, who)
		sendChat("Audio #" .. n .. ": " .. label(item) .. " - id " .. item.id)

	elseif sub == "grab" then
		local q = arg:gsub("^[iI][dD]%s+", "")
		if arg:lower() == "id" then q = "" end
		q = trim(q)
		if q == "" then
			hint(who, "/audio grab id <title> [author]")
			return
		end
		local title, author = splitTitleAuthor(q)
		local cands = findAudio(title, author, 1)
		if #cands == 0 then
			noneFound(true)
			return
		end
		copyId(cands[1].id, who)
		sendChat("Audio id " .. cands[1].id .. " - " .. label(cands[1]))

	elseif sub == "help" or sub == "cmds" or sub == "commands" then
		showHelp(arg)

	elseif sub == "strict" then
		if who ~= LocalPlayer then return end
		local m = arg:lower()
		if m == "on" or m == "off" then
			CONFIG.Strict = (m == "on")
			sendChat(CONFIG.Strict and "Strict search is ON: I only play and list audios that really contain the words searched."
				or "Strict search is OFF: if there's no exact match I play the closest audio.")
		else
			note("/audio strict on | off   (now: " .. (CONFIG.Strict and "on" or "off") .. ")")
		end

	elseif sub == "access" then
		if who ~= LocalPlayer then return end
		local m = arg:lower()
		if m == "everyone" or m == "friends" or m == "me" then
			CONFIG.Access = m
			sendChat("Boombox commands now work for: " .. (m == "everyone" and "everyone" or m == "friends" and "my Roblox friends" or "only me") .. ".")
		else
			note("/audio access everyone | friends | me   (now: " .. CONFIG.Access .. ")")
		end

	else
		hint(who, "Unknown /audio command. Type /cmds to see them all.")
	end
end

PLAT.ALIAS = { roblox = "audio", ["roblox audio"] = "audio", ["audio search"] = "audio", ["roblox audio search"] = "audio",
	creator = "audio", ["creator store"] = "audio", store = "audio", toolbox = "audio", search = "audio",
	["roblox catalog"] = "catalog", marketplace = "catalog", library = "catalog", ["roblox library"] = "catalog",
	den = "robloxden", ["roblox den"] = "robloxden", ["roblox music codes"] = "robloxden", ["music codes"] = "robloxden" }
PLAT.PRESET = { robloxden = "https://robloxden.com/music-codes" }

function PLAT.label(name)
	if name == "audio" then return "Roblox audio search" end
	if name == "catalog" then return "Roblox catalog" end
	local spec = PLAT.custom[name]
	return spec and spec.title or name
end

function PLAT.names()
	local out = { "audio", "catalog" }
	local extra = {}
	for n in pairs(PLAT.custom) do extra[#extra + 1] = n end
	for n in pairs(PLAT.PRESET) do
		if not PLAT.custom[n] then extra[#extra + 1] = n end
	end
	table.sort(extra)
	for _, n in ipairs(extra) do out[#out + 1] = n end
	return out
end

function PLAT.show()
	local names = {}
	for _, n in ipairs(PLAT.names()) do names[#names + 1] = (n == PLAT.cur) and ("[" .. n .. "]") or n end
	local now = PLAT.label(PLAT.cur) .. " (" .. PLAT.cur .. ")"
	if PLAT.cur == "audio" and PLAT.eff() == "catalog" then now = now .. " - using the catalog for a moment" end
	sendChat("Search platform: " .. now .. ". It is saved, so it stays after you rejoin.")
	sendList("Platforms:", names, ", ")
	sendChat("Change it with /search platform <name>. Add a site with /search platform add <name> <url> (put {q} where the search words go).")
end

function PLAT.use(name)
	PLAT.cur = name
	PLAT.down, PLAT.noted = false, false
	PLAT.save()
	sendChat("Search platform is now " .. PLAT.label(name) .. ". Saved - it stays after you rejoin or run the script again.")
end

function PLAT.test()
	LASTERR = nil
	local got = getItems("love", 0, 1)
	if #got == 0 then
		sendChat("Heads up: a test search on " .. PLAT.label(PLAT.cur) .. " found nothing, so it may be down or block scripts. /search platform audio goes back.")
		return false
	end
	return true
end

function PLAT.choose(arg)
	local key = clean(arg):lower()
	local name = key
	if not PLAT.custom[key] then name = PLAT.ALIAS[key] or key end
	if name == "audio" or name == "catalog" or PLAT.custom[name] then
		PLAT.use(name)
		if name ~= "audio" and name ~= "catalog" then PLAT.test() end
		return
	end
	local base = PLAT.PRESET[name]
	if base then
		sendChat("Checking how to search " .. name .. " (this takes a few seconds)...")
		local tpl = W.discover(base)
		if tpl then
			PLAT.custom[name] = { url = tpl, title = name }
			PLAT.use(name)
			PLAT.test()
		else
			sendChat("I couldn't find a search address for " .. name .. " - its search may run inside the web page, which scripts can't use. If you know its search link: /search platform add " .. name .. " <url with {q}>")
		end
		return
	end
	local hits = {}
	if #key >= 2 then
		for _, n in ipairs(PLAT.names()) do
			if n:sub(1, #key) == key then hits[#hits + 1] = n end
		end
	end
	if #hits == 1 then
		PLAT.choose(hits[1])
		return
	end
	sendChat("I don't know a platform called " .. key:sub(1, 24) .. ".")
	sendList("Platforms:", PLAT.names(), ", ")
end

function PLAT.add(arg)
	local name, url = arg:match("^(%S+)%s+(%S+)$")
	if not name then
		sendChat("Use /search platform add <name> <url>. Put {q} where the search words go, like <site>/search?q={q}. Without {q} I try to find the search myself.")
		return
	end
	name = name:lower()
	if not name:match("^[%w%-_]+$") or #name < 2 or #name > 20 then
		sendChat("Platform names are 2-20 letters, numbers or dashes.")
		return
	end
	local aliasOf = PLAT.ALIAS[name]
	if name == "audio" or name == "catalog" or (aliasOf and aliasOf ~= "robloxden") then
		sendChat("That name is taken - pick another one.")
		return
	end
	url = url:gsub("{query}", "{q}"):gsub("{search}", "{q}"):gsub("{term}", "{q}"):gsub("%%s", "{q}")
	if not url:match("^https?://[%w%-%.]+") then
		sendChat("The address has to start with http:// or https://")
		return
	end
	local host = url:match("^https?://([^/%?]+)") or name
	if not url:find("{q}", 1, true) then
		sendChat("Checking how to search " .. host .. " (a few seconds)...")
		local tpl = W.discover(url)
		if not tpl then
			sendChat("I couldn't find a search on that page. Give me the full search link with {q} where the words go.")
			return
		end
		url = tpl
	end
	PLAT.custom[name] = { url = url, title = name }
	PLAT.use(name)
	PLAT.test()
end

function PLAT.remove(arg)
	local name = clean(arg):lower()
	if name == "audio" or name == "catalog" then
		sendChat("The built-in platforms can't be removed.")
		return
	end
	if not PLAT.custom[name] then
		sendChat("There's no added platform called " .. name:sub(1, 20) .. ".")
		return
	end
	PLAT.custom[name] = nil
	if PLAT.cur == name then
		PLAT.use("audio")
	else
		PLAT.save()
	end
	sendChat("Removed the platform " .. name .. ".")
end

function PLAT.cmd(rest, who)
	who = who or LocalPlayer
	rest = trim(rest)
	local sub, arg = rest:match("^(%a+)%s*(.*)$")
	sub = sub and sub:lower() or ""
	arg = trim(arg or "")
	if sub ~= "platform" and sub ~= "source" and sub ~= "site" and sub ~= "engine" then
		if rest == "" then
			hint(who, "/search <words>   |   /search platform [name]")
			return
		end
		doAudio("search " .. rest, who)
		return
	end
	local s2, a2 = arg:match("^(%a+)%s*(.*)$")
	s2 = s2 and s2:lower() or ""
	a2 = trim(a2 or "")
	if arg == "" or s2 == "list" or s2 == "show" or s2 == "current" then
		PLAT.show()
		return
	end
	if who ~= LocalPlayer then
		sendChat("Only the boombox owner can change the search platform. Now: " .. PLAT.label(PLAT.cur) .. ".")
		return
	end
	LASTERR = nil
	if s2 == "add" then
		PLAT.add(a2)
	elseif s2 == "remove" or s2 == "delete" or s2 == "del" or s2 == "rm" then
		PLAT.remove(a2)
	else
		PLAT.choose(arg)
	end
end

local function fmtVol(v)
	if v == math.floor(v) then return tostring(math.floor(v)) end
	return tostring(v)
end

local function doVolume(rest, who)
	who = who or LocalPlayer
	local arg = trim(rest):lower()
	local tool = findBoombox()
	local cur = CONFIG.Volume
	local top = CONFIG.MaxVolume
	if arg == "" then
		if cur ~= nil then
			sendChat("Volume is " .. fmtVol(cur) .. " (0-" .. top .. "). Use /volume <0-" .. top .. "> to change it.")
		else
			sendChat("Volume is at the boombox's own level. Use /volume <0-" .. top .. "> to change it (" .. top .. " is the loudest).")
		end
		return
	end
	local function now()
		if cur ~= nil then return cur end
		local s = boomSounds(tool, NOW and NOW.id)[1]
		local ok, val = pcall(function() return s.Volume end)
		return (ok and tonumber(val)) or 1
	end
	local v
	local pct = arg:match("^(%d+%.?%d*)%%$")
	local num = arg:match("^(%d+%.?%d*)$") or arg:match("^(%.%d+)$")
	if pct then
		v = tonumber(pct) / 100 * top
	elseif num then
		v = tonumber(num)
	elseif arg == "up" or arg == "louder" or arg == "higher" or arg == "+" then
		v = now() + 1
	elseif arg == "down" or arg == "quieter" or arg == "lower" or arg == "-" then
		v = now() - 1
	elseif arg == "max" then
		v = top
	elseif arg == "mute" or arg == "off" then
		v = 0
	elseif arg:match("^%-%d") then
		sendChat("Volume goes from 0 to " .. top .. ".")
		return
	else
		hint(who, "/volume <0-" .. top .. ">   (also: up, down, max, mute, or a percent like 50%)")
		return
	end
	if v > top then v = top end
	if v < 0 then v = 0 end
	v = math.floor(v * 10 + 0.5) / 10
	CONFIG.Volume = v
	local n = applyVolume(tool, NOW and NOW.id)
	sendVolume(tool, v)
	if v >= top then
		sendChat("Volume set to " .. fmtVol(v) .. " - that's the loudest (" .. top .. ").")
	elseif v == 0 then
		sendChat("Volume muted (0).")
	else
		sendChat("Volume set to " .. fmtVol(v) .. " (0-" .. top .. ").")
	end
	if n == 0 then note("I couldn't find the boombox's sound right now, so the volume will be applied when the next audio plays.") end
end

local ALBUM_FILE = "BoomboxAlbums.json"
local ALBUMS = {}

local function saveAlbums()
	if not writefile then return end
	local data = { albums = {} }
	local uids = {}
	for uid in pairs(ALBUMS) do uids[#uids + 1] = uid end
	table.sort(uids)
	for _, uid in ipairs(uids) do
		for _, al in ipairs(ALBUMS[uid]) do
			local tr = {}
			for i, tk in ipairs(al.tracks) do tr[i] = { id = tk.id, name = tk.name, author = tk.author } end
			data.albums[#data.albums + 1] = { uid = uid, name = al.name, tracks = tr }
		end
	end
	pcall(function() writefile(ALBUM_FILE, HttpService:JSONEncode(data)) end)
end

local function loadAlbums()
	if not (isfile and readfile) then return end
	pcall(function()
		if not isfile(ALBUM_FILE) then return end
		local data = HttpService:JSONDecode(readfile(ALBUM_FILE))
		if type(data) ~= "table" then return end
		for _, e in ipairs(data.albums or {}) do
			local uid = tonumber(e.uid)
			if uid and type(e.name) == "string" then
				local list = ALBUMS[uid]
				if not list then
					list = {}
					ALBUMS[uid] = list
				end
				local tracks = {}
				for _, tk in ipairs(e.tracks or {}) do
					local id = tonumber(tk.id)
					if id then tracks[#tracks + 1] = { id = id, name = tostring(tk.name or ""), author = tostring(tk.author or "") } end
				end
				list[#list + 1] = { name = e.name, tracks = tracks }
			end
		end
	end)
end
loadAlbums()

local function dn(p) return tostring(p.DisplayName or p.Name):sub(1, 20) end

local function cleanName(s)
	s = clean(s)
	local inner = s:match("^%((.*)%)$") or s:match("^%[(.*)%]$") or s:match('^"(.*)"$')
	if inner then s = trim(inner) end
	return s
end

local function myAlbums(uid)
	local a = ALBUMS[uid]
	if not a then
		a = {}
		ALBUMS[uid] = a
	end
	return a
end

local function findAlbum(uid, name)
	local key = cleanName(name):lower()
	if key == "" then return nil end
	for i, al in ipairs(myAlbums(uid)) do
		if al.name:lower() == key then return al, i end
	end
	return nil
end

local function noAlbum(who, name)
	local mine = myAlbums(who.UserId)
	name = tostring(name or "")
	if #mine == 0 then
		sendChat(dn(who) .. ", you don't have any albums yet. Make one with /album create <name>.")
		return
	end
	local names = {}
	for _, al in ipairs(mine) do names[#names + 1] = al.name end
	sendList(dn(who) .. ", I can't find " .. (name ~= "" and ("an album called " .. name:sub(1, 24)) or "that album") .. ". Your albums:", names, " | ")
end

local function splitAlbumText(uid, text)
	text = trim(text)
	local whole = findAlbum(uid, text)
	if whole then return whole, "" end
	local a, b = text:match("^%(([^%)]+)%)%s*%(([^%)]+)%)$")
	if not a then a, b = text:match("^%[([^%]]+)%]%s*%[([^%]]+)%]$") end
	if not a then a, b = text:match("^(.-)%s*|%s*(.+)$") end
	if a then
		local al = findAlbum(uid, b)
		if al then return al, trim(a) end
		al = findAlbum(uid, a)
		if al then return al, trim(b) end
		return nil, trim(a), trim(b)
	end
	local words = {}
	for w in text:gmatch("%S+") do words[#words + 1] = w end
	for s = 2, #words do
		local al = findAlbum(uid, table.concat(words, " ", s))
		if al then return al, table.concat(words, " ", 1, s - 1) end
	end
	for e = #words - 1, 1, -1 do
		local al = findAlbum(uid, table.concat(words, " ", 1, e))
		if al then return al, table.concat(words, " ", e + 1) end
	end
	return nil, text
end

local function lookupId(id)
	local d = decode(httpGet("https://apis.roblox.com/toolbox-service/v1/items/details?assetIds=" .. id))
	if d then
		local out = {}
		collect(d, out, 0)
		for _, it in ipairs(out) do
			if it.id == id then return it end
		end
	end
	return { id = id, name = "", author = "" }
end

local function resolveAudio(text, who)
	text = trim(text)
	local low = text:lower()
	if low == "" then return nil, "none" end
	if low == "now" or low == "current" or low == "playing" or low == "this" then
		if NOW then return NOW end
		return nil, "nonow"
	end
	local direct = text:match("^#?(%d%d%d%d%d+)$")
	if direct then return lookupId(tonumber(direct)) end
	local small = text:match("^#?(%d%d?%d?%d?)$")
	if small then
		local it = lastOf(who.UserId).byIdx[tonumber(small)]
		if it then return it end
		return nil, "nosearch", small
	end
	local title, author = splitTitleAuthor(text)
	local res = findAudio(title, author, 1)
	if res[1] then return res[1] end
	return nil, "notfound"
end

local function matchTracks(al, text)
	text = trim(text)
	local out = {}
	if text == "" then return out end
	local big = text:match("^#?(%d%d%d%d%d+)$")
	if big then
		local id = tonumber(big)
		for i, tk in ipairs(al.tracks) do
			if tk.id == id then out[#out + 1] = i end
		end
		return out
	end
	local small = text:match("^#?(%d%d?%d?%d?)$")
	if small then
		local n = tonumber(small)
		if al.tracks[n] then out[1] = n end
		return out
	end
	local qw = wordsOf(text)
	if #qw == 0 then return out end
	local qn = table.concat(qw, " ")
	local exact = {}
	for i, tk in ipairs(al.tracks) do
		local nl, nset = wordsOf(tk.name)
		local _, aset = wordsOf(tk.author)
		local all = true
		for _, w in ipairs(qw) do
			if not nset[w] and not aset[w] then
				all = false
				break
			end
		end
		if all then
			out[#out + 1] = i
			if table.concat(nl, " ") == qn then exact[#exact + 1] = i end
		end
	end
	if #exact > 0 then return exact end
	return out
end

local function trackName(tk)
	return (tk.name ~= "" and tk.name or ("audio " .. tk.id))
end

local function albumCreate(who, arg)
	local name = cleanName(arg)
	if name == "" then
		hint(who, "/album create <name>")
		return
	end
	if #name > 24 then
		sendChat("Album names can be up to 24 characters.")
		return
	end
	local mine = myAlbums(who.UserId)
	if findAlbum(who.UserId, name) then
		sendChat(dn(who) .. ", you already have an album called " .. name .. ".")
		return
	end
	if #mine >= CONFIG.MaxAlbums then
		sendChat(dn(who) .. ", you can have up to " .. CONFIG.MaxAlbums .. " albums. Delete one with /album delete <name>.")
		return
	end
	mine[#mine + 1] = { name = name, tracks = {} }
	saveAlbums()
	sendChat(dn(who) .. " created the album " .. name .. ". Add audio with /album add <audio> " .. name .. " - only " .. dn(who) .. " can use it.")
end

local function albumAdd(who, arg)
	local uid = who.UserId
	local mine = myAlbums(uid)
	if arg == "" then
		hint(who, "/album add <audio> <album>   (audio = title [author], audio id, a number from /audio search, or now)")
		return
	end
	if #mine == 0 then
		noAlbum(who, "")
		return
	end
	local al, audioText, albumGuess = splitAlbumText(uid, arg)
	if not al then
		noAlbum(who, albumGuess or "")
		return
	end
	if #al.tracks >= CONFIG.MaxTracks then
		sendChat("The album " .. al.name .. " is full (" .. CONFIG.MaxTracks .. " audios).")
		return
	end
	LASTERR = nil
	local c, why, extra = resolveAudio(audioText, who)
	if not c then
		if why == "nonow" then
			sendChat("Nothing has played yet, so there's no current audio to add.")
		elseif why == "nosearch" then
			sendChat("I don't have audio #" .. tostring(extra) .. " from your last /audio search.")
		elseif why == "none" then
			hint(who, "/album add <audio> <album>")
		else
			noneFound(true)
		end
		return
	end
	for _, tk in ipairs(al.tracks) do
		if tk.id == c.id then
			sendChat(label(c) .. " is already in " .. al.name .. ".")
			return
		end
	end
	al.tracks[#al.tracks + 1] = { id = c.id, name = c.name or "", author = c.author or "" }
	saveAlbums()
	sendChat("Added " .. label(c) .. " (" .. c.id .. ") to " .. dn(who) .. "'s album " .. al.name .. " as track " .. #al.tracks .. ".")
end

local function albumDelete(who, arg)
	local name = cleanName(arg)
	if name == "" then
		hint(who, "/album delete <name>")
		return
	end
	local al, i = findAlbum(who.UserId, name)
	if not al then
		noAlbum(who, name)
		return
	end
	table.remove(myAlbums(who.UserId), i)
	saveAlbums()
	Q.dropAlbum(al)
	sendChat("Deleted the album " .. al.name .. " (" .. #al.tracks .. " audio" .. (#al.tracks == 1 and "" or "s") .. ").")
end

local function albumRemove(who, arg)
	local uid = who.UserId
	local mine = myAlbums(uid)
	if arg == "" then
		hint(who, "/album audio remove <audio> <album>   (audio = its number in /album list, its id or part of its title)")
		return
	end
	if #mine == 0 then
		noAlbum(who, "")
		return
	end
	local al, audioText, albumGuess = splitAlbumText(uid, arg)
	if not al and albumGuess then
		noAlbum(who, albumGuess)
		return
	end
	if al and audioText == "" then
		hint(who, "/album audio remove <audio> " .. al.name .. "   (see the numbers with /album list " .. al.name .. ")")
		return
	end
	local hits = {}
	if al then
		for _, i in ipairs(matchTracks(al, audioText)) do hits[#hits + 1] = { al = al, i = i } end
	else
		for _, a in ipairs(mine) do
			for _, i in ipairs(matchTracks(a, audioText)) do hits[#hits + 1] = { al = a, i = i } end
		end
		if #hits > 0 then
			local same = hits[1].al
			for _, h in ipairs(hits) do
				if h.al ~= same then
					same = nil
					break
				end
			end
			al = same
		end
	end
	if #hits == 0 then
		if al then
			sendChat("I can't find that audio in " .. al.name .. ". Use /album list " .. al.name .. " to see the numbers.")
		else
			sendChat("I can't find that audio in any of " .. dn(who) .. "'s albums.")
		end
		return
	end
	if #hits > 1 then
		local names = {}
		if al then
			for _, h in ipairs(hits) do names[#names + 1] = h.i .. ". " .. trackName(al.tracks[h.i]):sub(1, 30) end
			sendList("More than one audio matches in " .. al.name .. ":", names, " | ")
			sendChat("Use the number: /album audio remove <number> " .. al.name)
		else
			local seen = {}
			for _, h in ipairs(hits) do
				if not seen[h.al] then
					seen[h.al] = true
					names[#names + 1] = h.al.name
				end
			end
			sendList("That audio is in more than one album:", names, ", ")
			sendChat("Say which one: /album audio remove <audio> <album>")
		end
		return
	end
	local h = hits[1]
	local tk = table.remove(h.al.tracks, h.i)
	saveAlbums()
	sendChat("Removed " .. label(tk) .. " from " .. dn(who) .. "'s album " .. h.al.name .. ". " .. #h.al.tracks .. " audio(s) left.")
end

local function listAlbum(who, al, page)
	local per = CONFIG.PerPage
	local pages = math.max(1, math.ceil(#al.tracks / per))
	if page < 1 or page > pages then
		sendChat("The album " .. al.name .. " has " .. pages .. " page" .. (pages == 1 and "" or "s") .. ".")
		return
	end
	local entries = {}
	for i = (page - 1) * per + 1, math.min(#al.tracks, page * per) do
		local tk = al.tracks[i]
		entries[#entries + 1] = i .. ". " .. trackName(tk):sub(1, 40) .. (tk.author ~= "" and (" - " .. tk.author:sub(1, 18)) or "")
	end
	sendList(dn(who) .. "'s album " .. al.name .. " (" .. #al.tracks .. ") page " .. page .. "/" .. pages .. ":", entries, " | ")
	if pages > page then sendChat("Use /album list " .. al.name .. " " .. (page + 1) .. " for the next page.") end
end

local function albumList(who, arg)
	local uid = who.UserId
	local mine = myAlbums(uid)
	arg = cleanName(arg)
	if arg == "" then
		if #mine == 0 then
			sendChat(dn(who) .. " has no albums yet. Make one with /album create <name>.")
			return
		end
		local e = {}
		for _, al in ipairs(mine) do e[#e + 1] = al.name .. " (" .. #al.tracks .. ")" end
		sendList(dn(who) .. "'s albums:", e, " | ")
		return
	end
	local al, page = findAlbum(uid, arg), 1
	if not al then
		local base, n = arg:match("^(.-)%s+(%d+)$")
		if base then
			al = findAlbum(uid, base)
			page = tonumber(n)
		end
	end
	if not al then
		noAlbum(who, arg)
		return
	end
	if #al.tracks == 0 then
		sendChat("The album " .. al.name .. " is empty. Add audio with /album add <audio> " .. al.name .. ".")
		return
	end
	listAlbum(who, al, page)
end

function Q.measure(tool, c)
	for n = 1, 3 do
		local snd = findSound(c.id, tool)
		local len = snd and tonumber(snd.TimeLength) or 0
		if len > 0 then
			K.dur[c.id] = len
			return len
		end
		if n < 3 then task.wait(0.4) end
	end
	return nil
end

function Q.wait(tool, c, gen)
	local started, lastPos, lastLen, misses, cap = os.clock(), -1, 0, 0, 1500
	while gen == playGen and not gone do
		task.wait(0.5)
		if gen ~= playGen or gone then return true end
		if Q.skip then return true end
		if tool.Parent ~= getChar() then return false end
		local snd = findSound(c.id, tool, misses >= 2)
		if snd then
			misses = 0
			local pos = tonumber(snd.TimePosition) or 0
			local len = tonumber(snd.TimeLength) or 0
			if len > 0 then
				K.dur[c.id] = K.dur[c.id] or len
				cap = math.max(cap, len * 1.5 + 60)
				lastLen = len
				if pos >= len - 0.3 then return true end
			end
			if pos < lastPos - 1 then return true end
			lastPos = pos
		else
			misses = misses + 1
			if lastLen > 0 and lastPos >= lastLen - 1.2 then return true end
			if misses >= 3 then return true end
		end
		if os.clock() - started > cap then return true end
	end
	return true
end

function Q.doneAlbum(e)
	if e.album and e.i == e.n then
		sendChat("Album " .. e.album.name .. " finished (" .. e.run.played .. " played" .. (e.run.failed > 0 and (", " .. e.run.failed .. " skipped") or "") .. ").")
	end
end

function Q.play(e, gen)
	local tool = findBoombox()
	if not tool then
		sendChat("I need boombox.")
		Q.items = {}
		return false
	end
	local started, mismatch = nil, nil
	for i, c in ipairs(e.cands) do
		if gen ~= playGen or gone then return false end
		local ok = playFirstThatWorks(tool, { c }, gen, goodForm ~= nil or i > 1)
		if gen ~= playGen or gone then return false end
		if ok then
			Q.measure(tool, c)
			if e.kind and K.match(c, e.kind) == "no" then
				mismatch = c
			else
				started = c
				break
			end
		end
	end
	if not started then
		if e.album then
			sendChat("Skipping " .. label(e.cands[1]) .. " - it couldn't play (removed/banned?).")
			e.run.failed = e.run.failed + 1
		elseif mismatch then
			sendChat(label(mismatch) .. K.tag(mismatch) .. " isn't a " .. K.name[e.kind] .. ", so I skipped it.")
		else
			sendChat("That audio didn't play - it may have been removed/banned.")
			problem("Tried " .. #e.cands .. " audio(s) but none started on your boombox. Some boomboxes use a different control and can't be driven by a script.")
		end
		Q.doneAlbum(e)
		return false
	end
	e.now = started
	NOW = started
	if e.album then
		e.run.played = e.run.played + 1
		sendChat("Now playing (" .. e.i .. "/" .. e.n .. "): " .. label(started) .. " (" .. started.id .. ")" .. K.tag(started) .. " - " .. dn(e.who) .. "'s album " .. e.album.name)
	else
		local by = (e.who and e.who ~= LocalPlayer) and (" - requested by " .. dn(e.who)) or ""
		sendChat("Now playing: " .. label(started) .. " (" .. started.id .. ")" .. K.tag(started) .. by)
	end
	local more = Q.wait(tool, started, gen)
	if gen ~= playGen or gone then return true end
	if not more then
		Q.items = {}
		sendChat("The queue stopped (the boombox was put away).")
	end
	Q.doneAlbum(e)
	return true
end

function Q.finish(played, last)
	local tool = findBoombox()
	if tool and NOW then
		local snd = findSound(NOW.id, tool)
		if snd then
			fireAll(tool, "Stop")
			fireAll(tool, "StopSong")
		end
	end
	local note2 = Q.endNote
	Q.endNote = nil
	if note2 then
		sendChat(note2)
	elseif note2 == nil and played >= 2 and not (last and last.album) then
		sendChat("The queue is finished (" .. played .. " played).")
	end
end

function Q.loop(gen)
	local played, last = 0, nil
	local ok, err = pcall(function()
		while gen == playGen and not gone do
			local e = table.remove(Q.items, 1)
			if not e then break end
			last = e
			Q.cur = e
			Q.skip = false
			if Q.play(e, gen) then played = played + 1 end
		end
	end)
	if gen == playGen then
		Q.running = false
		Q.cur = nil
		Q.finish(played, last)
		if not ok and #Q.items > 0 and not gone then
			Q.running = true
			task.spawn(function() Q.loop(gen) end)
		end
	end
	if not ok then problem("Boombox script error: " .. tostring(err):sub(1, 150)) end
end

function Q.add(e)
	if #Q.items >= CONFIG.MaxQueue then
		sendChat("The queue is full (" .. CONFIG.MaxQueue .. " audios).")
		return false
	end
	if not e.album and e.who ~= LocalPlayer then
		local mine = 0
		for _, x in ipairs(Q.items) do
			if x.who == e.who and not x.album then mine = mine + 1 end
		end
		if mine >= CONFIG.MaxPerPlayer then
			sendChat(dn(e.who) .. ", you already have " .. mine .. " audios in the queue. Wait for some to play or use /queue remove.")
			return false
		end
	end
	Q.endNote = nil
	Q.items[#Q.items + 1] = e
	if not Q.running then
		Q.running = true
		local gen = playGen
		task.spawn(function() Q.loop(gen) end)
	elseif not e.album then
		local c = e.cands[1]
		local by = (e.who and e.who ~= LocalPlayer) and (" - requested by " .. dn(e.who)) or ""
		sendChat("Queued #" .. #Q.items .. ": " .. label(c) .. K.tag(c) .. by)
	end
	return true
end

function Q.stop()
	local had = Q.running or #Q.items > 0
	playGen = playGen + 1
	Q.items = {}
	Q.cur = nil
	Q.running = false
	Q.skip = false
	Q.endNote = nil
	stopBoombox()
	if had then sendChat("Stopped. The queue is cleared.") end
end

function Q.dropAlbum(al)
	for i = #Q.items, 1, -1 do
		if Q.items[i].album == al then table.remove(Q.items, i) end
	end
	if Q.cur and Q.cur.album == al then
		Q.skip = true
		Q.endNote = false
	end
end

function Q.line(i, e)
	local c = e.cands[1]
	local nm = (c.name ~= "" and c.name or ("audio " .. c.id)):sub(1, 28)
	local au = c.author ~= "" and (" - " .. c.author:sub(1, 14)) or ""
	return i .. ". " .. nm .. au .. K.tag(c) .. " (" .. dn(e.who):sub(1, 10) .. ")"
end

function Q.show()
	local n = #Q.items
	local cur = Q.cur
	local head = cur and ("Now: " .. label(cur.now or cur.cands[1]) .. ". ") or ""
	if n == 0 then
		sendChat(head .. "The queue is empty.")
		return
	end
	local entries = {}
	for i = 1, math.min(n, 8) do entries[i] = Q.line(i, Q.items[i]) end
	if n > 8 then entries[#entries + 1] = "+" .. (n - 8) .. " more" end
	sendList(head .. "Queue (" .. n .. "):", entries, " | ")
end

function Q.clear(who)
	local removed = 0
	for i = #Q.items, 1, -1 do
		if who == LocalPlayer or Q.items[i].who == who then
			table.remove(Q.items, i)
			removed = removed + 1
		end
	end
	if removed == 0 then
		sendChat("There was nothing of yours in the queue.")
	else
		sendChat("Removed " .. removed .. " audio" .. (removed == 1 and "" or "s") .. " from the queue.")
	end
end

function Q.remove(arg, who)
	if #Q.items == 0 then
		sendChat("The queue is empty.")
		return
	end
	arg = trim((arg:gsub("^#", "")))
	if arg == "" then
		hint(who, "/queue remove <number|title|last>   (the numbers are in /queue)")
		return
	end
	local low = arg:lower()
	if low == "all" then
		Q.clear(who)
		return
	end
	local idx = nil
	if low == "last" then
		for i = #Q.items, 1, -1 do
			if who == LocalPlayer or Q.items[i].who == who then
				idx = i
				break
			end
		end
		if not idx then
			sendChat("You have nothing in the queue to remove.")
			return
		end
	elseif arg:match("^%d+$") then
		idx = tonumber(arg)
		if not Q.items[idx] then
			sendChat("There's no #" .. idx .. " in the queue - it has " .. #Q.items .. ".")
			return
		end
	else
		local qw = wordsOf(arg)
		for i, e in ipairs(Q.items) do
			local c = e.cands[1]
			local _, nset = wordsOf(c.name .. " " .. c.author)
			local all = #qw > 0
			for _, w in ipairs(qw) do
				if not nset[w] then
					all = false
					break
				end
			end
			if all then
				idx = i
				break
			end
		end
		if not idx then
			sendChat("I can't find that in the queue.")
			return
		end
	end
	local e = Q.items[idx]
	if e.who ~= who and who ~= LocalPlayer then
		sendChat("Only " .. dn(e.who) .. " (who queued it) or the boombox owner can remove that.")
		return
	end
	table.remove(Q.items, idx)
	sendChat("Removed #" .. idx .. " from the queue: " .. label(e.cands[1]) .. ".")
end

function Q.cmdQueue(rest, who)
	who = who or LocalPlayer
	rest = trim(rest)
	local sub, arg = rest:match("^(%a*)%s*(.-)$")
	sub = (sub or ""):lower()
	arg = trim(arg or "")
	if (sub == "" and arg == "") or sub == "list" or sub == "show" then
		Q.show()
	elseif sub == "remove" or sub == "rm" or sub == "delete" or sub == "del" then
		Q.remove(arg, who)
	elseif sub == "clear" then
		Q.clear(who)
	else
		hint(who, "/queue   |   /queue remove <number|title|last>   |   /queue clear")
	end
end

function Q.cmdSkip(rest, who)
	local e = Q.cur
	if not e then
		sendChat("Nothing is playing right now.")
		return
	end
	local c = e.now or e.cands[1]
	local nxt = Q.items[1]
	Q.skip = true
	if nxt then
		Q.endNote = nil
		sendChat("Skipping " .. label(c) .. ". Next: " .. label(nxt.cands[1]) .. ".")
	else
		Q.endNote = "Skipped. The queue is empty, so I stopped the boombox."
		sendChat("Skipping " .. label(c) .. ".")
	end
end

local function albumLoad(who, arg)
	local uid = who.UserId
	local name = cleanName(arg)
	if name == "" then
		hint(who, "/album load <name>")
		return
	end
	local al = findAlbum(uid, name)
	if not al then
		noAlbum(who, name)
		return
	end
	if #al.tracks == 0 then
		sendChat("The album " .. al.name .. " is empty. Add audio with /album add <audio> " .. al.name .. ".")
		return
	end
	if not findBoombox() then
		sendChat("I need boombox.")
		return
	end
	local n = #al.tracks
	if #Q.items + n > CONFIG.MaxQueue then
		sendChat("The queue is too full for that album (" .. #Q.items .. "/" .. CONFIG.MaxQueue .. ").")
		return
	end
	local run = { played = 0, failed = 0 }
	local busy = Q.running
	sendChat((busy and "Queued " or "Loading ") .. dn(who) .. "'s album " .. al.name .. " (" .. n .. " audio" .. (n == 1 and "" or "s") .. ")" .. (busy and " after what's already queued." or "."))
	for i, tk in ipairs(al.tracks) do
		Q.add({ cands = { { id = tk.id, name = tk.name, author = tk.author } }, who = who, album = al, i = i, n = n, run = run })
	end
end

local function albumControl(who, what)
	local has = (Q.cur and Q.cur.album) and Q.cur or nil
	if not has then
		for _, e in ipairs(Q.items) do
			if e.album then
				has = e
				break
			end
		end
	end
	if not has then
		sendChat("No album is playing right now.")
		return
	end
	if who ~= has.who and who ~= LocalPlayer then
		sendChat("Only " .. dn(has.who) .. " (who loaded the album) or the boombox owner can do that.")
		return
	end
	if what == "skip" then
		if Q.cur and Q.cur.album then
			Q.skip = true
			sendChat("Skipping to the next audio.")
		else
			sendChat("The album is waiting in the queue - it hasn't started yet.")
		end
	else
		Q.dropAlbum(has.album)
		sendChat("Album stopped.")
	end
end

local function doAlbum(rest, who)
	who = who or LocalPlayer
	rest = trim(rest)
	local sub, arg = rest:match("^(%a+)%s*(.*)$")
	sub = sub and sub:lower() or ""
	arg = trim(arg)
	if sub == "" then
		hint(who, "/album create <name> | load <name> | add <audio> <album> | delete <name> | audio remove <audio> <album> | list [name] | skip | stop")
	elseif sub == "help" then
		showHelp("album " .. arg)
	elseif sub == "create" or sub == "new" or sub == "make" then
		albumCreate(who, arg)
	elseif sub == "load" or sub == "play" then
		albumLoad(who, arg)
	elseif sub == "add" then
		albumAdd(who, arg)
	elseif sub == "delete" or sub == "del" or sub == "destroy" then
		albumDelete(who, arg)
	elseif sub == "remove" or sub == "rm" then
		albumRemove(who, arg)
	elseif sub == "list" or sub == "show" or sub == "view" or sub == "albums" then
		albumList(who, arg)
	elseif sub == "skip" or sub == "stop" then
		albumControl(who, sub)
	elseif sub == "audio" or sub == "song" or sub == "track" then
		local s2, a2 = arg:match("^(%a+)%s*(.*)$")
		s2 = s2 and s2:lower() or ""
		a2 = trim(a2)
		if s2 == "remove" or s2 == "rm" or s2 == "delete" or s2 == "del" then
			albumRemove(who, a2)
		elseif s2 == "add" then
			albumAdd(who, a2)
		elseif s2 == "list" then
			albumList(who, a2)
		else
			hint(who, "/album audio remove <audio> <album>   |   /album audio add <audio> <album>")
		end
	else
		hint(who, "Unknown /album command. Type /audio help album to see them.")
	end
end

do
	local RunService = game:GetService("RunService")
	local FLY = { on = false, tool = nil, handle = nil, angle = 0, nextFind = 0, nextParent = 0, orig = {} }
	local HIDE = { on = false, list = {}, conns = {}, equipAt = -100, watched = setmetatable({}, { __mode = "k" }) }
	local WORDS = { "boom", "music", "radio", "jukebox", "stereo", "song", "audio" }
	local gui, flyBtn, hideBtn, flyConn
	local refresh

	local function gripOf(char, handle)
		for _, hname in ipairs({ "RightHand", "Right Arm" }) do
			local hand = char:FindFirstChild(hname)
			if hand then
				for _, j in ipairs(hand:GetChildren()) do
					if j.Name == "RightGrip" and j.Part1 == handle then return j, hand end
				end
			end
		end
		return nil
	end

	local function releaseGrips()
		for grip, c0 in pairs(FLY.orig) do
			pcall(function() grip.C0 = c0 end)
		end
		FLY.orig = {}
	end

	local function flyStep(dt)
		local char = getChar()
		local hrp = char and char:FindFirstChild("HumanoidRootPart")
		local hum = getHum()
		if not hrp or not hum or hum.Health <= 0 then return end
		local now = os.clock()
		local tool = FLY.tool
		if not tool or not tool.Parent then
			if now < FLY.nextFind then return end
			FLY.nextFind = now + 0.5
			tool = findBoombox()
			FLY.tool, FLY.handle = tool, nil
			if not tool then return end
			UI.watch(tool)
		end
		if tool.Parent ~= char then
			if now < FLY.nextParent then return end
			FLY.nextParent = now + 0.25
			pcall(function() tool.Parent = char end)
			return
		end
		local handle = FLY.handle
		if not handle or handle.Parent ~= tool then
			handle = tool:FindFirstChild("Handle") or tool:FindFirstChildWhichIsA("BasePart")
			FLY.handle = handle
			if not handle then return end
		end
		local grip, hand = gripOf(char, handle)
		if not grip then return end
		if FLY.orig[grip] == nil then FLY.orig[grip] = grip.C0 end
		FLY.angle = FLY.angle + dt * 1.5
		local a = FLY.angle
		local center = hrp.Position
		local pos = center + Vector3.new(math.cos(a) * 5, 2.5 + math.sin(a * 2) * 0.6, math.sin(a) * 5)
		local target = CFrame.new(pos, center + Vector3.new(0, 2, 0))
		grip.C0 = hand.CFrame:Inverse() * target * grip.C1
	end

	local function setFly(on)
		if on == FLY.on then return true end
		if on then
			local tool = findBoombox()
			if not tool then
				note("I need boombox.")
				return false
			end
			FLY.on, UI.fly = true, true
			FLY.tool, FLY.handle, FLY.nextParent = tool, nil, 0
			UI.watch(tool)
			if tool.Parent ~= getChar() then pcall(function() tool.Parent = getChar() end) end
			flyConn = RunService.Heartbeat:Connect(function(dt)
				local ok, err = pcall(flyStep, dt)
				if not ok then FLY.err = err end
			end)
		else
			FLY.on, UI.fly = false, false
			if flyConn then
				flyConn:Disconnect()
				flyConn = nil
			end
			releaseGrips()
		end
		refresh()
		return true
	end

	local function boomName(n)
		n = tostring(n):lower()
		for _, w in ipairs(WORDS) do
			if n:find(w, 1, true) then return true end
		end
		return false
	end

	local function hideGui(sg)
		if HIDE.list[sg] ~= nil then return end
		local ok, was = pcall(function()
			local e = sg.Enabled
			sg.Enabled = false
			return e
		end)
		if not ok then return end
		HIDE.list[sg] = (was ~= false)
		pcall(function()
			HIDE.conns[#HIDE.conns + 1] = sg:GetPropertyChangedSignal("Enabled"):Connect(function()
				if HIDE.on and sg.Enabled then sg.Enabled = false end
			end)
		end)
	end

	UI.watch = function(tool)
		if not HIDE.on or HIDE.watched[tool] then return end
		HIDE.watched[tool] = true
		pcall(function()
			HIDE.conns[#HIDE.conns + 1] = tool.Equipped:Connect(function() HIDE.equipAt = os.clock() end)
		end)
	end

	local function setHide(on)
		if on == HIDE.on then return true end
		HIDE.on, UI.hide = on, on
		if on then
			local pg = LocalPlayer:FindFirstChildOfClass("PlayerGui")
			if pg then
				for _, sg in ipairs(pg:GetChildren()) do
					if sg:IsA("ScreenGui") and not OWN_GUI[sg.Name] and boomName(sg.Name) then hideGui(sg) end
				end
				pcall(function()
					HIDE.conns[#HIDE.conns + 1] = pg.ChildAdded:Connect(function(sg)
						if HIDE.on and sg:IsA("ScreenGui") and not OWN_GUI[sg.Name]
							and (boomName(sg.Name) or os.clock() - HIDE.equipAt < 3) then
							hideGui(sg)
						end
					end)
				end)
			end
			local tool = findBoombox()
			if tool then UI.watch(tool) end
		else
			for _, c in ipairs(HIDE.conns) do pcall(function() c:Disconnect() end) end
			HIDE.conns = {}
			HIDE.watched = setmetatable({}, { __mode = "k" })
			for sg, wasOn in pairs(HIDE.list) do
				if wasOn then pcall(function() sg.Enabled = true end) end
			end
			HIDE.list = {}
		end
		refresh()
		return true
	end

	local cmdBtn, panel
	local CMD_ROWS = {
		"/play <title> [author] [sfx|long|song]",
		"/play random [genre] [sfx|long|song]",
		"/play <audio id>",
		"/play pick <number>",
		"/play stop",
		"/skip",
		"/queue",
		"/queue remove <number|title|last>",
		"/queue clear",
		"/audio search <words> [page 1-1000]",
		"/audio next",
		"/audio prev",
		"/audio id <number>",
		"/audio grab id <title> [author]",
		"/audio help [command]",
		"/cmds",
		"/volume <0-10>",
		"/album create <name>",
		"/album load <name>",
		"/album add <audio> <album>",
		"/album delete <name>",
		"/album audio remove <audio> <album>",
		"/album list [name]",
		"/album skip",
		"/album stop",
		"/search <words>",
		"/search platform [name]",
		"/search platform add <name> <url>",
		"/search platform remove <name>",
		"/whitelist <player>",
		"/blacklist <player>",
		"/audio access everyone|friends|me",
		"/audio strict on|off",
	}

	local function corner(obj, r)
		pcall(function()
			local c = Instance.new("UICorner")
			c.CornerRadius = UDim.new(0, r)
			c.Parent = obj
		end)
	end

	local function copyText(text)
		local f = setclipboard or toclipboard or writeclipboard
		if not f then
			note("Your executor has no clipboard function, so I can't copy that.")
			return false
		end
		return pcall(f, text)
	end

	local function flash(b, text)
		local old = b.Text
		b.Text = text
		task.spawn(function()
			task.wait(0.8)
			if b.Parent then b.Text = old end
		end)
	end

	local function paint(btn, name, on)
		btn.Text = name .. "\n" .. (on and "ON" or "OFF")
		btn.BackgroundColor3 = on and Color3.fromRGB(46, 160, 90) or Color3.fromRGB(32, 34, 40)
	end

	refresh = function()
		if flyBtn then paint(flyBtn, "FLY", FLY.on) end
		if hideBtn then paint(hideBtn, "HIDE", HIDE.on) end
		if cmdBtn then paint(cmdBtn, "CMDS", panel ~= nil and panel.Visible == true) end
	end

	local function makeButton(parent, name, x, y, w, h)
		local b = Instance.new("TextButton")
		b.Name = name
		b.Size = UDim2.new(0, w, 0, h)
		b.Position = UDim2.new(0, x, 0, y)
		b.BorderSizePixel = 0
		b.AutoButtonColor = true
		b.TextColor3 = Color3.fromRGB(255, 255, 255)
		b.TextSize = 10
		b.TextWrapped = true
		pcall(function() b.Font = Enum.Font.GothamBold end)
		corner(b, 6)
		b.Parent = parent
		return b
	end

	local function buildPanel(parent)
		panel = Instance.new("Frame")
		panel.Name = "CommandsPanel"
		panel.AnchorPoint = Vector2.new(1, 0)
		panel.Position = UDim2.new(1, -8, 0.5, 22)
		panel.Size = UDim2.new(0, 240, 0, 220)
		panel.BackgroundColor3 = Color3.fromRGB(22, 24, 29)
		panel.BorderSizePixel = 0
		panel.Visible = false
		corner(panel, 8)
		panel.Parent = parent
		local head = Instance.new("TextLabel")
		head.Name = "Title"
		head.BackgroundTransparency = 1
		head.Position = UDim2.new(0, 8, 0, 4)
		head.Size = UDim2.new(0, 150, 0, 18)
		head.TextXAlignment = Enum.TextXAlignment.Left
		head.TextColor3 = Color3.fromRGB(220, 224, 232)
		head.TextSize = 11
		pcall(function() head.Font = Enum.Font.GothamBold end)
		head.Text = "Commands - tap to copy"
		head.Parent = panel
		local all = makeButton(panel, "CopyAllButton", 162, 4, 70, 18)
		all.BackgroundColor3 = Color3.fromRGB(52, 90, 160)
		all.Text = "COPY ALL"
		all.Activated:Connect(function()
			flash(all, copyText(table.concat(CMD_ROWS, "\n")) and "Copied!" or "Can't copy")
		end)
		local list = Instance.new("ScrollingFrame")
		list.Name = "List"
		list.BackgroundTransparency = 1
		list.BorderSizePixel = 0
		list.Position = UDim2.new(0, 4, 0, 26)
		list.Size = UDim2.new(1, -8, 1, -30)
		list.ScrollBarThickness = 3
		list.Parent = panel
		local y = 0
		for i, text in ipairs(CMD_ROWS) do
			local lines = math.max(1, math.ceil(#text / 36))
			local h = lines * 12 + 8
			local b = makeButton(list, "Cmd" .. i, 0, y, 220, h)
			b.Size = UDim2.new(1, -6, 0, h)
			b.BackgroundColor3 = Color3.fromRGB(34, 37, 45)
			b.TextXAlignment = Enum.TextXAlignment.Left
			b.Text = text
			b.Activated:Connect(function()
				flash(b, copyText(text) and "Copied!" or "Can't copy")
			end)
			y = y + h + 3
		end
		list.CanvasSize = UDim2.new(0, 0, 0, y)
	end

	pcall(function()
		gui = Instance.new("ScreenGui")
		gui.Name = "BoomboxToggles"
		gui.ResetOnSpawn = false
		gui.DisplayOrder = 50
		local holder = Instance.new("Frame")
		holder.Name = "Holder"
		holder.BackgroundTransparency = 1
		holder.AnchorPoint = Vector2.new(1, 0.5)
		holder.Position = UDim2.new(1, -8, 0.5, 0)
		holder.Size = UDim2.new(0, 134, 0, 30)
		holder.Parent = gui
		flyBtn = makeButton(holder, "FlyButton", 0, 0, 42, 30)
		hideBtn = makeButton(holder, "HideGuiButton", 46, 0, 42, 30)
		cmdBtn = makeButton(holder, "CmdsButton", 92, 0, 42, 30)
		buildPanel(gui)
		flyBtn.Activated:Connect(function() setFly(not FLY.on) end)
		hideBtn.Activated:Connect(function() setHide(not HIDE.on) end)
		cmdBtn.Activated:Connect(function()
			panel.Visible = not panel.Visible
			refresh()
		end)
		local hosts = {}
		pcall(function()
			if gethui then hosts[#hosts + 1] = gethui() end
		end)
		pcall(function() hosts[#hosts + 1] = game:GetService("CoreGui") end)
		hosts[#hosts + 1] = LocalPlayer:FindFirstChildOfClass("PlayerGui")
		local placed = false
		for _, host in ipairs(hosts) do
			if not placed then
				pcall(function()
					local old = host:FindFirstChild("BoomboxToggles")
					if old then old:Destroy() end
					gui.Parent = host
				end)
				if gui.Parent == host then placed = true end
			end
		end
		if placed then
			made[#made + 1] = gui
			refresh()
		else
			gui = nil
		end
	end)

	cleanupFns[#cleanupFns + 1] = function()
		setFly(false)
		setHide(false)
		if gui then pcall(function() gui:Destroy() end) end
	end
end

local ACCESS_FILE = "BoomboxAccess.json"
local WL, BL, NAMES = {}, {}, {}

local function saveLists()
	if not writefile then return end
	local data = { wl = {}, bl = {} }
	for id in pairs(WL) do data.wl[#data.wl + 1] = { id = id, name = NAMES[id] or "" } end
	for id in pairs(BL) do data.bl[#data.bl + 1] = { id = id, name = NAMES[id] or "" } end
	pcall(function() writefile(ACCESS_FILE, HttpService:JSONEncode(data)) end)
end

local function loadLists()
	if not (isfile and readfile) then return end
	pcall(function()
		if not isfile(ACCESS_FILE) then return end
		local data = HttpService:JSONDecode(readfile(ACCESS_FILE))
		if type(data) ~= "table" then return end
		for _, e in ipairs(data.wl or {}) do
			local id = tonumber(e.id)
			if id then
				WL[id] = true
				NAMES[id] = e.name
			end
		end
		for _, e in ipairs(data.bl or {}) do
			local id = tonumber(e.id)
			if id then
				BL[id] = true
				NAMES[id] = e.name
			end
		end
	end)
end
loadLists()

local function findPlayers(q)
	q = (trim(q):lower():gsub("^@", ""))
	if q == "" then return {} end
	local tiers = { {}, {}, {} }
	for _, p in ipairs(Players:GetPlayers()) do
		if p ~= LocalPlayer then
			local n, d = p.Name:lower(), p.DisplayName:lower()
			if n == q or d == q then
				tiers[1][#tiers[1] + 1] = p
			elseif n:sub(1, #q) == q or d:sub(1, #q) == q then
				tiers[2][#tiers[2] + 1] = p
			elseif n:find(q, 1, true) or d:find(q, 1, true) then
				tiers[3][#tiers[3] + 1] = p
			end
		end
	end
	for _, t in ipairs(tiers) do
		if #t > 0 then return t end
	end
	return {}
end

local function resolveTarget(arg)
	local low = arg:lower()
	if low == LocalPlayer.Name:lower() or low == LocalPlayer.DisplayName:lower() then return nil, "me" end
	local idStr = arg:match("^(%d%d%d%d%d+)$")
	if idStr then
		local uid = tonumber(idStr)
		if uid == LocalPlayer.UserId then return nil, "me" end
		local p = Players:GetPlayerByUserId(uid)
		local name = p and p.Name
		if not name then
			local ok, n = pcall(function() return Players:GetNameFromUserIdAsync(uid) end)
			if ok and type(n) == "string" then name = n end
		end
		if not name then return nil, "none" end
		return { id = uid, name = name }
	end
	local found = findPlayers(arg)
	if #found == 0 then return nil, "none" end
	if #found > 1 then
		local names = {}
		for _, p in ipairs(found) do names[#names + 1] = p.Name end
		return nil, "many", names
	end
	return { id = found[1].UserId, name = found[1].Name }
end

local function listAccess()
	local w, b = {}, {}
	for id in pairs(WL) do w[#w + 1] = NAMES[id] ~= nil and NAMES[id] ~= "" and NAMES[id] or tostring(id) end
	for id in pairs(BL) do b[#b + 1] = NAMES[id] ~= nil and NAMES[id] ~= "" and NAMES[id] or tostring(id) end
	table.sort(w)
	table.sort(b)
	sendList("Whitelist:", #w > 0 and w or { "nobody" }, ", ")
	sendList("Blacklist:", #b > 0 and b or { "nobody" }, ", ")
end

local function setAccessFor(kind, arg, who)
	if who ~= LocalPlayer then return end
	arg = trim(arg)
	if arg == "" or arg:lower() == "list" then
		listAccess()
		return
	end
	local t, why, names = resolveTarget(arg)
	if not t then
		if why == "me" then
			sendChat("That's me - I can always use my own commands.")
		elseif why == "many" then
			sendChat("More than one player matches: " .. table.concat(names, ", "):sub(1, 120) .. ". Be more specific.")
		else
			sendChat("I can't find that player.")
		end
		return
	end
	NAMES[t.id] = t.name
	if kind == "white" then
		BL[t.id] = nil
		WL[t.id] = true
		sendChat(t.name .. " can now use my boombox commands.")
	else
		WL[t.id] = nil
		BL[t.id] = true
		sendChat(t.name .. " can no longer use my boombox commands.")
	end
	saveLists()
end

local HANDLERS = {
	play = doPlay,
	audio = doAudio,
	cmds = showCmds,
	album = doAlbum,
	skip = Q.cmdSkip,
	queue = Q.cmdQueue,
	search = PLAT.cmd,
	volume = doVolume,
	whitelist = function(r, w) setAccessFor("white", r, w) end,
	blacklist = function(r, w) setAccessFor("black", r, w) end,
}

local seenCmd = {}
local lastCmdAt = {}
local friendCache = {}
local function isAllowed(plr)
	if plr == LocalPlayer then return true end
	if BL[plr.UserId] then return false end
	if WL[plr.UserId] then return true end
	local mode = CONFIG.Access
	if mode == "everyone" then return true end
	if mode == "friends" then
		local f = friendCache[plr.UserId]
		if f == nil then
			local ok, r = pcall(function() return LocalPlayer:IsFriendsWith(plr.UserId) end)
			f = ok and r == true
			friendCache[plr.UserId] = f
		end
		return f
	end
	return false
end

dispatch = function(text, speaker)
	speaker = speaker or LocalPlayer
	text = trim(text)
	local cmd, rest = text:match("^/(%a+)%s*(.*)$")
	if not cmd then return end
	cmd = cmd:lower()
	local handler = HANDLERS[cmd]
	if not handler then return end
	local now = os.clock()
	local key = speaker.UserId .. ":" .. text
	if seenCmd[key] and now - seenCmd[key] < 1.5 then return end
	seenCmd[key] = now
	if next(seenCmd) and math.random(20) == 1 then
		for k, t in pairs(seenCmd) do
			if now - t > 10 then seenCmd[k] = nil end
		end
	end
	if not isAllowed(speaker) then return end
	if speaker ~= LocalPlayer then
		if now - (lastCmdAt[speaker.UserId] or -1e9) < CONFIG.Cooldown then return end
		lastCmdAt[speaker.UserId] = now
	end
	task.spawn(function()
		local ok, err = pcall(handler, rest, speaker)
		if not ok then problem("Boombox script error: " .. tostring(err):sub(1, 150)) end
	end)
end

local registered = false
pcall(function()
	if TextChatService.ChatVersion ~= Enum.ChatVersion.TextChatService then return end
	local folder = TextChatService:FindFirstChild("TextChatCommands") or TextChatService:WaitForChild("TextChatCommands", 5)
	if not folder then return end
	for _, alias in ipairs({ "/play", "/audio", "/album", "/volume", "/cmds", "/whitelist", "/blacklist", "/skip", "/queue", "/search" }) do
		local cmd = Instance.new("TextChatCommand")
		cmd.Name = "BoomboxCmd_" .. alias:sub(2)
		cmd.PrimaryAlias = alias
		cmd.Parent = folder
		made[#made + 1] = cmd
		track(cmd.Triggered:Connect(function(_, text) dispatch(text) end))
		registered = true
	end
end)
track(LocalPlayer.Chatted:Connect(function(msg) dispatch(msg, LocalPlayer) end))

hookChannels()
pcall(function()
	local channels = TextChatService:FindFirstChild("TextChannels")
	if channels then track(channels.ChildAdded:Connect(function() hookChannels() end)) end
end)
local function hookPlayer(p)
	if p == LocalPlayer then return end
	track(p.Chatted:Connect(function(msg) dispatch(msg, p) end))
end
for _, p in ipairs(Players:GetPlayers()) do hookPlayer(p) end
track(Players.PlayerAdded:Connect(hookPlayer))

env.__BoomboxDispatch = function(text) dispatch(text, LocalPlayer) end
env.__BoomboxCleanup = function()
	gone = true
	for _, f in ipairs(cleanupFns) do pcall(f) end
	for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
	for _, cmd in ipairs(made) do pcall(function() cmd:Destroy() end) end
	env.__BoomboxDispatch = nil
	env.__BoomboxCleanup = nil
end

banner((registered and "Boombox commands ready: /play, /skip, /queue, /audio, /album and /volume (type /cmds for the list)" or "Boombox commands ready (old chat mode): /play, /skip, /queue, /audio, /album and /volume (type /cmds for the list)")
	.. ". Who can use them: " .. CONFIG.Access, 40, 120, 60, 8)
