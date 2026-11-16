-- SERVANT (one file): paste ALL of this into Delta and press Execute.
-- You should see a blue bar at the top of the screen saying it started.
local function banner(text, r, g, b, secs)
	pcall(function()
		local lp = game:GetService("Players").LocalPlayer
		local pg = lp and lp:FindFirstChild("PlayerGui")
		if not pg then return end
		local sg = Instance.new("ScreenGui")
		sg.Name = "ServantBanner"
		sg.ResetOnSpawn = false
		sg.IgnoreGuiInset = true
		sg.DisplayOrder = 2147483647
		local l = Instance.new("TextLabel")
		l.Position = UDim2.fromOffset(10, 10)
		l.Size = UDim2.new(1, -20, 0, 0)
		l.AutomaticSize = Enum.AutomaticSize.Y
		l.BackgroundColor3 = Color3.fromRGB(r, g, b)
		l.BackgroundTransparency = 0.1
		l.TextColor3 = Color3.new(1, 1, 1)
		l.TextWrapped = true
		l.TextSize = 16
		l.Font = Enum.Font.GothamBold
		l.Text = text
		l.Parent = sg
		sg.Parent = pg
		task.delay(secs, function() sg:Destroy() end)
	end)
end
banner("Servant: script received, starting...", 50, 110, 220, 5)
local SRC = [==[
--[[
	SERVANT SCRIPT v2  (client-side, run it in your executor)

	SETUP
	1. Tap/click the round "S" button (drag it anywhere). A textbox slides out to its left.
	2. Type the start of your owner's username/display name (e.g. "war") + Enter.
	   Empty box + Enter releases your owner. Changing owner makes you say "I now serve <name>".
	3. The owner (and anyone they add with .owner) controls you with chat commands starting with ".".
	   Type .cmds for the list, .help <cmd> for details.

	AUTO-EXECUTE (rejoin / server hop)
	- Save this file as  ServantScript.lua  in your executor's "workspace" folder.
	- Put the small ServantAutoexec.lua file in your executor's "autoexec" folder.
	- Your owner list is saved to ServantSave.json and restored automatically.
]]

local env = (getgenv and getgenv()) or _G
if env.__ServantCleanup then pcall(env.__ServantCleanup) end

if not game:IsLoaded() then game.Loaded:Wait() end

----------------------------------------------------------------------
-- Services
----------------------------------------------------------------------
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local StarterGui = game:GetService("StarterGui")
local TextChatService = game:GetService("TextChatService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PathfindingService = game:GetService("PathfindingService")
local ContextActionService = game:GetService("ContextActionService")
local HttpService = game:GetService("HttpService")
local Workspace = game:GetService("Workspace")

while not Players.LocalPlayer do task.wait() end
local LocalPlayer = Players.LocalPlayer
env.__ServantJob = game.JobId

----------------------------------------------------------------------
-- Config (tweak freely)
----------------------------------------------------------------------
local CONFIG = {
	Prefix = ".",
	SaveFile = "ServantSave.json",
	ScriptFile = "ServantScript.lua",
	LeashLength = 9,
	LeashSegments = 14,
	SecurityRadius = 20,
	DefaultFlySpeed = 60,
	DefaultThrow = 120,
	DefaultFling = 250,
	DefaultSpin = 20,
	CarpetSinkSpeed = 2.5,
	SpeedBoostExtra = 12,
	OrbitSpeed = 2.5,
	OrbitRadius = 7,
	KneelTime = 10,
	StarPlatinumTime = 4.5,
	KissTime = 5.2,
	TurnRate = 100, -- degrees/second for .mleft / .mright
}

-- Catalog emote animation IDs (from memory). Any that fail to load are skipped.
local R15_EMOTES = {
	"3360692915", "3360686498", "3361481910", "3333331310", "3338025566", "3695333486",
	"4265725525", "4265701731", "4212455378", "4210116953", "4049037604", "4641985101",
	"4391208058", "5938365243", "5917459365", "3337994105",
}
local R15_DEFAULT_DANCES = { "507771019", "507776043", "507777268" }
local R6_DEFAULT_DANCES = { "182435998", "182491037", "182491065" }

----------------------------------------------------------------------
-- State
----------------------------------------------------------------------
local S = {
	ownerId = nil, ownerName = nil, co = {},
	attach = nil, attachTarget = nil, attachGen = 0, attachT0 = 0, attachUntil = 0, attachStartCF = nil,
	grabPhase = nil,
	fly = false, flySpeed = CONFIG.DefaultFlySpeed,
	dancing = false, danceGen = 0, danceTrack = nil,
	spin = false, spinSpeed = CONFIG.DefaultSpin, spinAngle = 0,
	freeze = false, muted = false,
	security = false, secGen = 0, secTarget = nil, chasing = false, flinging = false,
	ncList = {}, ncMine = nil, ncDone = {},
	leash = false, leashTarget = nil,
	walkSpeed = nil, jumpPower = nil,
	limpUntil = 0, noclipUntil = 0, psApplied = false,
	carpetY = nil, kneelPos = nil,
	spReturn = nil, spTarget = nil, spFixed = nil, spLastPop = 0,
	kissHearts = false,
	orbitAngle = 0, orbitSpeed = CONFIG.OrbitSpeed, orbitRadius = CONFIG.OrbitRadius,
	locks = {}, warned = false,
	pa = nil, animOff = false,
	mimic = false, mimicTarget = nil, mimicTracks = {}, mimicWS = false,
	mv = { on = false, dirv = 0, turn = 0, jumps = 0, loop = false, untilT = nil, heading = 0, lastJump = 0 },
	ud = false, udVy = 0, udYaw = 0, udPitch = 0, udDist = 12, udFace = nil, udGravity = nil, udTracks = nil,
	flingGen = 0,
}
local orig = { walk = 16, jump = 50, useJP = true }
local conns = {}
local function track(c)
	conns[#conns + 1] = c
	return c
end

-- forward declarations (assigned further down)
local setFly, stopAttach, beginAttach, clearMove, stopMimic, stopPose, playPose, clearPose
local setUpside, sendChat, startDance, stopAll, protectAuth

----------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------
local function rotOnly(cf) return cf - cf.Position end
local function flat(v) return Vector3.new(v.X, 0, v.Z) end
local function clampNum(n, lo, hi) return math.max(lo, math.min(hi, n)) end
local function smooth(a) return a * a * (3 - 2 * a) end
local function toNum(s, default, lo, hi)
	local n = tonumber(s)
	if not n then return default end
	return clampNum(n, lo, hi)
end
local function trim(s) return (s or ""):match("^%s*(.-)%s*$") end

local function notify(text, title)
	pcall(function()
		StarterGui:SetCore("SendNotification", { Title = title or "Servant", Text = text, Duration = 4 })
	end)
end

local function getChar() return LocalPlayer.Character end
local function getHum()
	local c = getChar()
	return c and c:FindFirstChildOfClass("Humanoid")
end
local function getHRP()
	local c = getChar()
	return c and c:FindFirstChild("HumanoidRootPart")
end
local function plrOf(uid) return uid and Players:GetPlayerByUserId(uid) or nil end
local function charOf(uid)
	local p = plrOf(uid)
	return p and p.Character
end
local function hrpOf(uid)
	local c = charOf(uid)
	return c and c:FindFirstChild("HumanoidRootPart")
end
local function handPosOf(uid)
	local ochar = charOf(uid)
	if not ochar then return nil end
	local h = ochar:FindFirstChild("RightHand")
	if h then return h.Position end
	local arm = ochar:FindFirstChild("Right Arm")
	if arm then return (arm.CFrame * CFrame.new(0, -1, 0)).Position end
	local oh = ochar:FindFirstChild("HumanoidRootPart")
	return oh and (oh.Position + oh.CFrame.RightVector * 1.5) or nil
end
local function isAuth(uid) return uid ~= nil and (uid == S.ownerId or S.co[uid] == true) end
local function eachAuth(fn)
	if S.ownerId then fn(S.ownerId) end
	for id in pairs(S.co) do fn(id) end
end
local function standHeight(hum, hrp)
	if hum and hum.RigType == Enum.HumanoidRigType.R15 then
		return hum.HipHeight + hrp.Size.Y / 2
	end
	return 3
end

local parts = {}
local function rebuildParts(char)
	parts = {}
	for _, d in ipairs(char:GetDescendants()) do
		if d:IsA("BasePart") then parts[#parts + 1] = d end
	end
end

local function safeParent(gui)
	-- PlayerGui first: always visible on mobile. Hidden-UI containers are only a fallback.
	local ok = pcall(function() gui.Parent = LocalPlayer:WaitForChild("PlayerGui", 10) end)
	if not ok or not gui.Parent then
		pcall(function() if syn and syn.protect_gui then syn.protect_gui(gui) end end)
		pcall(function() if protectgui then protectgui(gui) end end)
		pcall(function() gui.Parent = (gethui and gethui()) or game:GetService("CoreGui") end)
	end
end

local function findPlayer(q)
	q = trim(q):lower()
	if q == "" then return nil end
	local list = Players:GetPlayers()
	table.sort(list, function(x, y) return x.Name:lower() < y.Name:lower() end)
	for _, p in ipairs(list) do
		if p ~= LocalPlayer and (p.Name:lower() == q or p.DisplayName:lower() == q) then return p end
	end
	for _, p in ipairs(list) do
		if p ~= LocalPlayer and (p.Name:lower():sub(1, #q) == q or p.DisplayName:lower():sub(1, #q) == q) then return p end
	end
	for _, p in ipairs(list) do
		if p ~= LocalPlayer and (p.Name:lower():find(q, 1, true) or p.DisplayName:lower():find(q, 1, true)) then return p end
	end
	return nil
end

----------------------------------------------------------------------
-- Saved owners (survive rejoin / server hop)
----------------------------------------------------------------------
local function saveData()
	if not writefile then return end
	local co = {}
	for id in pairs(S.co) do co[#co + 1] = id end
	pcall(function()
		writefile(CONFIG.SaveFile, HttpService:JSONEncode({ owner = S.ownerId, ownerName = S.ownerName, co = co }))
	end)
end

local function loadData()
	if not (isfile and readfile) then return end
	local ok, data = pcall(function()
		if isfile(CONFIG.SaveFile) then return HttpService:JSONDecode(readfile(CONFIG.SaveFile)) end
	end)
	if ok and type(data) == "table" then
		if type(data.owner) == "number" then
			S.ownerId = data.owner
			S.ownerName = data.ownerName
		end
		if type(data.co) == "table" then
			for _, id in ipairs(data.co) do
				if type(id) == "number" then S.co[id] = true end
			end
		end
	end
end

----------------------------------------------------------------------
-- Movement lock (used by .follow, .security chase, .mimic, m-commands)
----------------------------------------------------------------------
local controlsObj, controlsTried, controlsLocked = nil, false, false
local function sinkAction() return Enum.ContextActionResult.Sink end

local function getControls()
	if controlsObj then return controlsObj end
	if controlsTried then return nil end
	controlsTried = true
	pcall(function()
		local ps = LocalPlayer:WaitForChild("PlayerScripts", 5)
		local pm = ps and ps:WaitForChild("PlayerModule", 5)
		if pm then controlsObj = require(pm):GetControls() end
	end)
	return controlsObj
end
task.spawn(getControls)

local function applyLock()
	local want = next(S.locks) ~= nil
	if want == controlsLocked then return end
	controlsLocked = want
	local c = getControls()
	if c then
		pcall(function()
			if want then c:Disable() else c:Enable() end
		end)
	end
	if want and not c then
		ContextActionService:BindActionAtPriority("ServantLock", sinkAction, false, 3000,
			Enum.KeyCode.W, Enum.KeyCode.A, Enum.KeyCode.S, Enum.KeyCode.D,
			Enum.KeyCode.Up, Enum.KeyCode.Down, Enum.KeyCode.Left, Enum.KeyCode.Right,
			Enum.KeyCode.Space, Enum.KeyCode.Thumbstick1)
	elseif not want then
		ContextActionService:UnbindAction("ServantLock")
	end
end

local function setLock(reason, on)
	S.locks[reason] = on or nil
	applyLock()
end

----------------------------------------------------------------------
-- Chat: sending, and mute (chat input block + overlay)
----------------------------------------------------------------------
sendChat = function(text)
	text = tostring(text):sub(1, 200)
	local sent = false
	if TextChatService.ChatVersion == Enum.ChatVersion.TextChatService then
		pcall(function()
			local channels = TextChatService:FindFirstChild("TextChannels")
			local general = channels and channels:FindFirstChild("RBXGeneral")
			if general then
				general:SendAsync(text)
				sent = true
			end
		end)
	end
	if not sent then
		pcall(function()
			local ev = ReplicatedStorage:FindFirstChild("DefaultChatSystemChatEvents")
			local say = ev and ev:FindFirstChild("SayMessageRequest")
			if say then say:FireServer(text, "All") end
		end)
	end
end

local blockGui = Instance.new("ScreenGui")
blockGui.Name = "ServantMute_" .. tostring(math.random(100000, 999999))
blockGui.ResetOnSpawn = false
blockGui.IgnoreGuiInset = true
blockGui.DisplayOrder = 2147483646
blockGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
local blocker = Instance.new("TextButton")
blocker.Text = ""
blocker.AutoButtonColor = false
blocker.Active = true
blocker.BackgroundTransparency = 1
blocker.BorderSizePixel = 0
blocker.Position = UDim2.fromOffset(0, 40)
blocker.Size = UDim2.fromOffset(470, 340)
blocker.Visible = false
blocker.Parent = blockGui
local mutedTag = Instance.new("TextLabel")
mutedTag.BackgroundColor3 = Color3.fromRGB(150, 40, 50)
mutedTag.BackgroundTransparency = 0.25
mutedTag.Text = "  Muted by owner  "
mutedTag.TextColor3 = Color3.new(1, 1, 1)
mutedTag.Font = Enum.Font.GothamBold
mutedTag.TextSize = 12
mutedTag.AnchorPoint = Vector2.new(0, 1)
mutedTag.Position = UDim2.new(0, 6, 1, -6)
mutedTag.Size = UDim2.fromOffset(110, 20)
mutedTag.Parent = blocker
Instance.new("UICorner", mutedTag).CornerRadius = UDim.new(0, 6)
safeParent(blockGui)

local chatBarPrev = nil
local function applyChatBlock(on)
	pcall(function()
		local cfg = TextChatService:FindFirstChildOfClass("ChatInputBarConfiguration")
		if cfg then
			if on then
				if chatBarPrev == nil then chatBarPrev = cfg.Enabled end
				if cfg.Enabled then cfg.Enabled = false end
			elseif chatBarPrev ~= nil then
				cfg.Enabled = chatBarPrev
				chatBarPrev = nil
			end
		end
	end)
	pcall(function()
		local pg = LocalPlayer:FindFirstChild("PlayerGui")
		local chat = pg and pg:FindFirstChild("Chat")
		local bar = chat and chat:FindFirstChild("ChatBarParentFrame", true)
		if bar then bar.Visible = not on end
	end)
	blocker.Visible = on
	if on then
		ContextActionService:BindActionAtPriority("ServantMuteSlash", sinkAction, false, 3000, Enum.KeyCode.Slash)
	else
		ContextActionService:UnbindAction("ServantMuteSlash")
	end
end

local function setMute(on)
	S.muted = on
	applyChatBlock(on)
end

----------------------------------------------------------------------
-- Animations: tracks, dance, praise, Animate suspend
----------------------------------------------------------------------
local function isR15()
	local h = getHum()
	return h and h.RigType == Enum.HumanoidRigType.R15
end

local function getAnimator(hum)
	local animator = hum:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = hum
	end
	return animator
end

local function loadTrack(id)
	local hum = getHum()
	if not hum then return nil end
	local anim = Instance.new("Animation")
	anim.AnimationId = "rbxassetid://" .. id
	local ok, tr = pcall(function() return getAnimator(hum):LoadAnimation(anim) end)
	if ok then return tr end
	return nil
end

local function shuffled(list)
	local t = {}
	for i, v in ipairs(list) do t[i] = v end
	for i = #t, 2, -1 do
		local j = math.random(i)
		t[i], t[j] = t[j], t[i]
	end
	return t
end

local function stopDanceTrack()
	if S.danceTrack then
		pcall(function() S.danceTrack:Stop() end)
		S.danceTrack = nil
	end
end

startDance = function()
	stopDanceTrack()
	S.danceGen = S.danceGen + 1
	local gen = S.danceGen
	local pool = {}
	if isR15() then
		for _, id in ipairs(shuffled(R15_EMOTES)) do pool[#pool + 1] = id end
		for _, id in ipairs(shuffled(R15_DEFAULT_DANCES)) do pool[#pool + 1] = id end
	else
		for _, id in ipairs(shuffled(R6_DEFAULT_DANCES)) do pool[#pool + 1] = id end
	end
	task.spawn(function()
		for _, id in ipairs(pool) do
			if not S.dancing or S.danceGen ~= gen then return end
			local tr = loadTrack(id)
			if tr then
				tr.Priority = Enum.AnimationPriority.Action4
				tr.Looped = true
				tr:Play()
				local t0 = os.clock()
				while tr.Length == 0 and os.clock() - t0 < 1.2 do task.wait() end
				if tr.Length > 0 then
					if S.dancing and S.danceGen == gen then
						S.danceTrack = tr
					else
						tr:Stop()
					end
					return
				end
				pcall(function() tr:Stop() end)
			end
		end
	end)
end

local function setDance(on)
	S.dancing = on
	if on then
		startDance()
	else
		S.danceGen = S.danceGen + 1
		stopDanceTrack()
	end
end

local function playTemp(id, secs)
	local tr = loadTrack(id)
	if not tr then return end
	tr.Priority = Enum.AnimationPriority.Action4
	tr.Looped = false
	tr:Play()
	task.delay(secs, function() pcall(function() tr:Stop() end) end)
end

local function stopAllTracks()
	local hum = getHum()
	local animator = hum and hum:FindFirstChildOfClass("Animator")
	if animator then
		for _, t in ipairs(animator:GetPlayingAnimationTracks()) do
			pcall(function() t:Stop(0.1) end)
		end
	end
end

-- The default Animate script is switched off while a custom pose / mimic is running
local function syncAnimate()
	local want = (S.pa ~= nil) or S.mimic
	if want == S.animOff then return end
	S.animOff = want
	local char = getChar()
	local anim = char and char:FindFirstChild("Animate")
	if anim then
		pcall(function() anim.Disabled = want end)
		pcall(function() anim.Enabled = not want end)
	end
	if want then
		stopAllTracks()
		S.danceTrack = nil
	elseif S.dancing then
		startDance()
	end
end

----------------------------------------------------------------------
-- Pose engine (hand-keyed Motor6D animation, blended in/out)
----------------------------------------------------------------------
local JOINT_NAMES = {
	RS = { "RightShoulder", "Right Shoulder" }, LS = { "LeftShoulder", "Left Shoulder" },
	RE = { "RightElbow" }, LE = { "LeftElbow" },
	RH = { "RightHip", "Right Hip" }, LH = { "LeftHip", "Left Hip" },
	RK = { "RightKnee" }, LK = { "LeftKnee" },
	WA = { "Waist" }, NK = { "Neck" },
}

local function collectJoints(char)
	local found = {}
	for _, d in ipairs(char:GetDescendants()) do
		if d:IsA("Motor6D") then
			for key, names in pairs(JOINT_NAMES) do
				for _, n in ipairs(names) do
					if d.Name == n and not found[key] then
						found[key] = { m = d, c0 = d.C0 }
					end
				end
			end
		end
	end
	return found
end

local ZERO3 = { 0, 0, 0 }
local function lerpPose(a, b, t)
	local keys, out = {}, {}
	for k in pairs(a) do keys[k] = true end
	for k in pairs(b) do keys[k] = true end
	for k in pairs(keys) do
		local pa, pb = a[k] or ZERO3, b[k] or ZERO3
		out[k] = {
			pa[1] + (pb[1] - pa[1]) * t,
			pa[2] + (pb[2] - pa[2]) * t,
			pa[3] + (pb[3] - pa[3]) * t,
		}
	end
	return out
end

local function evalKeys(keys, t)
	if t <= keys[1][1] then return keys[1][2] end
	for i = 1, #keys - 1 do
		local k0, k1 = keys[i], keys[i + 1]
		if t < k1[1] then
			local a = (t - k0[1]) / (k1[1] - k0[1])
			return lerpPose(k0[2], k1[2], smooth(a))
		end
	end
	return keys[#keys][2]
end

local function restoreJoints(pa)
	for _, j in pairs(pa.joints) do
		if j.m.Parent then j.m.C0 = j.c0 end
	end
end

clearPose = function()
	if S.pa then
		restoreJoints(S.pa)
		S.pa = nil
	end
end

playPose = function(def)
	clearPose()
	local char = getChar()
	if not char then return end
	S.pa = { def = def, t0 = os.clock(), joints = collectJoints(char), char = char, blend = 0, ending = nil }
end

stopPose = function()
	if S.pa and not S.pa.ending then S.pa.ending = os.clock() end
end

local function poseStep(dt)
	local pa = S.pa
	if not pa then return end
	if pa.char ~= getChar() then
		S.pa = nil
		return
	end
	local now = os.clock()
	local t = now - pa.t0
	local def = pa.def
	if def.duration and t >= def.duration and not pa.ending then pa.ending = now end
	local target = pa.ending and 0 or 1
	local step = dt / (def.fade or 0.35)
	if pa.blend < target then
		pa.blend = math.min(target, pa.blend + step)
	else
		pa.blend = math.max(target, pa.blend - step)
	end
	local pose = def.fn and def.fn(t) or evalKeys(def.keys, math.min(t, def.duration or t))
	local w = smooth(pa.blend)
	for key, j in pairs(pa.joints) do
		if j.m.Parent then
			local p = pose[key]
			if p and w > 0 then
				j.m.C0 = CFrame.new(j.c0.Position)
					* CFrame.fromEulerAnglesYXZ(math.rad(p[1]) * w, math.rad(p[2]) * w, math.rad(p[3]) * w)
					* rotOnly(j.c0)
			else
				j.m.C0 = j.c0
			end
		end
	end
	if pa.ending and pa.blend <= 0 then
		restoreJoints(pa)
		S.pa = nil
	end
end

-- Poses (degrees: {pitch, yaw, roll} in the parent part's space; +pitch swings a limb forward)
local POSES = {}

POSES.stand = { fade = 0.5, keys = {
	{ 0, {} },
	{ 0.6, { RS = { 38, 42, 0 }, LS = { 38, -42, 0 }, RE = { 118, 0, 0 }, LE = { 118, 0, 0 },
		WA = { -4, 0, 0 }, NK = { -4, 0, 0 }, RH = { 4, 0, 0 }, LH = { 4, 0, 0 } } },
} }

POSES.push = { fade = 0.4, keys = {
	{ 0, {} },
	{ 0.4, { RS = { 82, 8, 0 }, LS = { 82, -8, 0 }, RE = { 8, 0, 0 }, LE = { 8, 0, 0 },
		WA = { -12, 0, 0 }, NK = { 10, 0, 0 }, RH = { -18, 0, 0 }, LH = { 12, 0, 0 },
		RK = { -22, 0, 0 }, LK = { -6, 0, 0 } } },
} }

POSES.float = { fade = 0.5, keys = {
	{ 0, {} },
	{ 0.6, { RS = { 0, 0, 28 }, LS = { 0, 0, -28 }, RE = { 20, 0, 0 }, LE = { 20, 0, 0 },
		RH = { 6, 0, 3 }, LH = { -4, 0, -3 }, RK = { -12, 0, 0 }, LK = { -8, 0, 0 } } },
} }

POSES.kneel = { fade = 0.6, keys = {
	{ 0, {} },
	{ 1.0, { RH = { -8, 0, 4 }, RK = { -88, 0, 0 }, LH = { 88, 0, -3 }, LK = { -88, 0, 0 },
		WA = { -10, 0, 0 }, NK = { -22, 0, 0 },
		RS = { 45, 35, 0 }, RE = { 112, 0, 0 }, LS = { 30, 0, 0 }, LE = { 28, 0, 0 } } },
} }

POSES.kiss = { duration = CONFIG.KissTime, fade = 0.45, keys = {
	{ 0, {} },
	{ 0.8, { RS = { 88, 26, 0 }, LS = { 88, -26, 0 }, RE = { 50, 0, 0 }, LE = { 50, 0, 0 },
		WA = { -3, 0, 0 }, NK = { -2, 0, 0 } } },
	{ 1.5, { RS = { 108, 34, 0 }, LS = { 108, -34, 0 }, RE = { 72, 0, 0 }, LE = { 72, 0, 0 },
		WA = { -13, 0, 0 }, NK = { 14, 0, -11 }, RH = { -6, 0, 0 }, LH = { 3, 0, 0 }, RK = { -18, 0, 0 } } },
	{ 1.9, { RS = { 110, 34, 0 }, LS = { 110, -34, 0 }, RE = { 74, 0, 0 }, LE = { 74, 0, 0 },
		WA = { -15, 0, 0 }, NK = { 15, 3, -13 }, RH = { -24, 0, 2 }, LH = { 4, 0, 0 }, RK = { -52, 0, 0 } } },
	{ 2.7, { RS = { 110, 34, 0 }, LS = { 110, -34, 0 }, RE = { 74, 0, 0 }, LE = { 74, 0, 0 },
		WA = { -15, 0, 0 }, NK = { 13, 2, -12 }, RH = { -26, 0, 2 }, LH = { 4, 0, 0 }, RK = { -58, 0, 0 } } },
	{ 3.3, { RS = { 110, 34, 0 }, LS = { 110, -34, 0 }, RE = { 74, 0, 0 }, LE = { 74, 0, 0 },
		WA = { -16, 0, 0 }, NK = { 16, 3, -14 }, RH = { -24, 0, 2 }, LH = { 4, 0, 0 }, RK = { -54, 0, 0 } } },
	{ 4.0, { RS = { 92, 28, 0 }, LS = { 92, -28, 0 }, RE = { 54, 0, 0 }, LE = { 54, 0, 0 },
		WA = { -6, 0, 0 }, NK = { 4, 0, -4 }, RH = { -6, 0, 0 }, RK = { -16, 0, 0 } } },
	{ CONFIG.KissTime, {} },
} }

local function punchExt(t, phase)
	local s = (t * 3.6 + phase) % 1
	if s < 0.35 then return math.sin(s / 0.35 * math.pi / 2) end
	return math.cos((s - 0.35) / 0.65 * math.pi / 2)
end
POSES.punch = { fade = 0.25, fn = function(t)
	local r, l = punchExt(t, 0), punchExt(t, 0.5)
	return {
		RS = { 30 + 62 * r, 8, 0 }, RE = { 120 - 112 * r, 0, 0 },
		LS = { 30 + 62 * l, -8, 0 }, LE = { 120 - 112 * l, 0, 0 },
		WA = { -9, (r - l) * 16, 0 }, NK = { 4, (l - r) * 10, 0 },
		RH = { -16, 0, 4 }, LH = { 14, 0, -4 }, RK = { -26, 0, 0 }, LK = { -12, 0, 0 },
	}
end }

local ATTACH_POSE = {
	stand = "stand", speedboost = "push", orbit = "float",
	kneel = "kneel", kiss = "kiss", starplat = "punch",
}

----------------------------------------------------------------------
-- Floating text pops (ORA!, hearts) - local only
----------------------------------------------------------------------
local function popText(part, text, color, font)
	if not (part and part.Parent) then return end
	local bb = Instance.new("BillboardGui")
	bb.Size = UDim2.fromOffset(140, 46)
	bb.StudsOffset = Vector3.new(math.random(-25, 25) / 10, math.random(0, 20) / 10, 0)
	bb.AlwaysOnTop = true
	bb.Adornee = part
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Size = UDim2.fromScale(1, 1)
	l.Text = text
	l.Font = font or Enum.Font.GothamBlack
	l.TextScaled = true
	l.TextColor3 = color or Color3.fromRGB(120, 90, 255)
	l.TextStrokeTransparency = 0.2
	l.Parent = bb
	bb.Parent = part
	local goal = bb.StudsOffset + Vector3.new(0, 2.5, 0)
	TweenService:Create(bb, TweenInfo.new(0.8, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { StudsOffset = goal }):Play()
	TweenService:Create(l, TweenInfo.new(0.8), { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
	task.delay(0.9, function() bb:Destroy() end)
end

----------------------------------------------------------------------
-- Manual movement commands (.mforward .mbackward .mleft .mright .mjump)
----------------------------------------------------------------------
clearMove = function()
	local mv = S.mv
	if not mv.on then return end
	mv.on, mv.dirv, mv.turn, mv.jumps, mv.loop, mv.untilT = false, 0, 0, 0, false, nil
	setLock("mmove", false)
	local hum = getHum()
	if hum then
		hum:Move(Vector3.zero, false)
		hum.AutoRotate = not S.spin
	end
end

local function ensureMove()
	local mv = S.mv
	local hrp, hum = getHRP(), getHum()
	if not (hrp and hum) then return false end
	if S.attach then stopAttach() end
	stopMimic()
	if not mv.on then
		mv.on = true
		local look = flat(hrp.CFrame.LookVector)
		mv.heading = look.Magnitude > 0.01 and math.atan2(-look.X, -look.Z) or 0
		hum.AutoRotate = false
		setLock("mmove", true)
	end
	return true
end

local function mvStep(hrp, hum, dt, now)
	local mv = S.mv
	if not mv.on or S.attach or S.ud then return end
	if mv.untilT and now > mv.untilT then
		mv.dirv = 0
		mv.untilT = nil
	end
	mv.heading = mv.heading + math.rad(CONFIG.TurnRate) * mv.turn * dt
	local dir = Vector3.new(-math.sin(mv.heading), 0, -math.cos(mv.heading))
	hum:Move(dir * mv.dirv, false)
	if not S.fly and not S.spin then
		hrp.CFrame = CFrame.new(hrp.Position) * CFrame.Angles(0, mv.heading, 0)
	end
	if (mv.loop or mv.jumps > 0) and hum.FloorMaterial ~= Enum.Material.Air and now - mv.lastJump > 0.4 then
		mv.lastJump = now
		hum.Jump = true
		if mv.jumps > 0 then mv.jumps = mv.jumps - 1 end
	end
	if mv.dirv == 0 and mv.turn == 0 and not mv.loop and mv.jumps <= 0 then clearMove() end
end

----------------------------------------------------------------------
-- Mimic (copy the target's movement + playing animations)
----------------------------------------------------------------------
stopMimic = function()
	if not S.mimic then return end
	S.mimic = false
	for _, tr in pairs(S.mimicTracks) do pcall(function() tr:Stop(0.1) end) end
	S.mimicTracks = {}
	setLock("mimic", false)
	local hum = getHum()
	if hum then
		hum:Move(Vector3.zero, false)
		hum.AutoRotate = not S.spin
		if S.mimicWS and not S.walkSpeed then hum.WalkSpeed = orig.walk end
	end
	S.mimicWS = false
end

local function startMimic(uid)
	stopAttach()
	setFly(false)
	clearMove()
	setUpside(false)
	stopMimic()
	S.mimic = true
	S.mimicTarget = uid
	S.mimicTracks = {}
	setLock("mimic", true)
	local hum = getHum()
	if hum then hum.AutoRotate = false end
end

local function mimicStep(hrp, hum)
	local ochar, oh = charOf(S.mimicTarget), hrpOf(S.mimicTarget)
	local ohum = ochar and ochar:FindFirstChildOfClass("Humanoid")
	if not (oh and ohum) then return end
	local v = flat(oh.AssemblyLinearVelocity)
	if v.Magnitude > 1.5 then hum:Move(v.Unit, false) else hum:Move(Vector3.zero, false) end
	if not S.walkSpeed and hum.WalkSpeed ~= ohum.WalkSpeed then
		hum.WalkSpeed = ohum.WalkSpeed
		S.mimicWS = true
	end
	if not S.spin and not S.attach then
		local lv = flat(oh.CFrame.LookVector)
		if lv.Magnitude > 0.01 then hrp.CFrame = CFrame.lookAt(hrp.Position, hrp.Position + lv) end
	end
	if oh.AssemblyLinearVelocity.Y > 15 and hum.FloorMaterial ~= Enum.Material.Air then hum.Jump = true end
	local oAnimator = ohum:FindFirstChildOfClass("Animator")
	if not oAnimator then return end
	local myAnimator = getAnimator(hum)
	local seen = {}
	for _, t in ipairs(oAnimator:GetPlayingAnimationTracks()) do
		local id = t.Animation and t.Animation.AnimationId
		if id and id ~= "" and t.WeightTarget > 0.01 then
			seen[id] = true
			local mine = S.mimicTracks[id]
			if not mine then
				local a = Instance.new("Animation")
				a.AnimationId = id
				local ok, tr = pcall(function() return myAnimator:LoadAnimation(a) end)
				if ok and tr then
					tr.Priority = t.Priority
					tr.Looped = t.Looped
					S.mimicTracks[id] = tr
					mine = tr
				end
			end
			if mine then
				if not mine.IsPlaying then mine:Play(0.1, 1, t.Speed) end
				mine:AdjustSpeed(t.Speed)
				mine:AdjustWeight(t.WeightTarget)
				if math.abs(mine.TimePosition - t.TimePosition) > 0.4 and mine.Length > 0 then
					mine.TimePosition = t.TimePosition
				end
			end
		end
	end
	for id, tr in pairs(S.mimicTracks) do
		if not seen[id] and tr.IsPlaying then tr:Stop(0.15) end
	end
end

----------------------------------------------------------------------
-- Attach modes (grab / headsit / sword / vest / carpet / follow / stand /
-- speedboost / orbit / kneel / kiss / starplat)
----------------------------------------------------------------------
stopAttach = function()
	local prev = S.attach
	S.attach = nil
	S.attachGen = S.attachGen + 1
	S.grabPhase = nil
	S.carpetY = nil
	S.kneelPos = nil
	setLock("follow", false)
	stopPose()
	local hum, hrp = getHum(), getHRP()
	if hum and (prev == "grab" or prev == "headsit") then hum.Sit = false end
	if prev == "vest" then
		for _, p in ipairs(parts) do
			if p.Parent then p.CanTouch = true end
		end
	end
	if prev == "follow" and hum and hrp then hum:MoveTo(hrp.Position) end
	if prev and hrp and not S.freeze then hrp.AssemblyLinearVelocity = Vector3.zero end
end

setFly = function(on, speed)
	S.fly = on
	if speed then S.flySpeed = speed end
	if on then
		stopAttach()
		setUpside(false)
	else
		local hrp = getHRP()
		if hrp then
			for _, n in ipairs({ "ServantFlyBV", "ServantFlyBG" }) do
				local o = hrp:FindFirstChild(n)
				if o then o:Destroy() end
			end
		end
	end
end

beginAttach = function(name, uid)
	stopAttach()
	setFly(false)
	clearMove()
	stopMimic()
	setUpside(false)
	S.attach = name
	S.attachTarget = uid
	S.attachGen = S.attachGen + 1
	S.attachT0 = os.clock()
	S.attachUntil = 0
	S.carpetY = nil
	S.kneelPos = nil
	local hrp = getHRP()
	S.attachStartCF = hrp and hrp.CFrame
	local pose = ATTACH_POSE[name]
	if pose then playPose(POSES[pose]) end
end

local function flyStep(hrp, hum)
	local bv = hrp:FindFirstChild("ServantFlyBV")
	if not bv then
		bv = Instance.new("BodyVelocity")
		bv.Name = "ServantFlyBV"
		bv.MaxForce = Vector3.new(1e9, 1e9, 1e9)
		bv.Velocity = Vector3.zero
		bv.Parent = hrp
	end
	local bg = hrp:FindFirstChild("ServantFlyBG")
	if not bg then
		bg = Instance.new("BodyGyro")
		bg.Name = "ServantFlyBG"
		bg.MaxTorque = Vector3.new(1e9, 1e9, 1e9)
		bg.P = 2e4
		bg.D = 500
		bg.CFrame = hrp.CFrame
		bg.Parent = hrp
	end
	local cf = Workspace.CurrentCamera.CFrame
	local md = hum.MoveDirection
	local fwd, right = 0, 0
	if md.Magnitude > 0.05 then
		local fl, fr = flat(cf.LookVector), flat(cf.RightVector)
		if fl.Magnitude > 0.01 then fwd = md:Dot(fl.Unit) end
		if fr.Magnitude > 0.01 then right = md:Dot(fr.Unit) end
	end
	local up = 0
	if not UserInputService:GetFocusedTextBox() then
		if UserInputService:IsKeyDown(Enum.KeyCode.Space) or UserInputService:IsKeyDown(Enum.KeyCode.E) then up = up + 1 end
		if UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) or UserInputService:IsKeyDown(Enum.KeyCode.Q)
			or UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) then up = up - 1 end
	end
	if hum.Jump then up = up + 1 end
	local target = cf.LookVector * fwd + cf.RightVector * right + Vector3.new(0, up, 0)
	if target.Magnitude > 1 then target = target.Unit end
	bv.Velocity = bv.Velocity:Lerp(target * S.flySpeed, 0.3)
	bg.CFrame = cf
end

local function groundBelow(pos, char, ochar)
	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Exclude
	rp.FilterDescendantsInstances = { char, ochar or char, Workspace.CurrentCamera }
	local hit = Workspace:Raycast(pos + Vector3.new(0, 4, 0), Vector3.new(0, -40, 0), rp)
	return hit and hit.Position.Y or nil
end

-- Per-frame placement for CFrame-driven attach modes
local function attachStep(char, hrp, hum, dt, now)
	local a = S.attach
	if not a or a == "follow" then return end
	local ochar, oh = charOf(S.attachTarget), hrpOf(S.attachTarget)
	if not (ochar and oh) then return end
	local cf
	local velOut = Vector3.zero

	if a == "grab" then
		if not hum.Sit then hum.Sit = true end
		if S.grabPhase == "armed" then
			local d = hrp.Position - oh.Position
			local fd = flat(d)
			if fd.Magnitude < 4.5 and math.abs(d.Y) < 4 then
				local fl = flat(oh.CFrame.LookVector)
				if fl.Magnitude > 0.01 and (fd.Magnitude < 0.3 or fl.Unit:Dot(fd.Unit) > 0.55) then
					S.grabPhase = "held"
				end
			end
			return
		end
		cf = oh.CFrame * CFrame.new(0, -0.4, -2.6) * CFrame.Angles(0, math.pi, 0)

	elseif a == "headsit" then
		if not hum.Sit then hum.Sit = true end
		local head = ochar:FindFirstChild("Head")
		local base = head and head.Position or (oh.Position + Vector3.new(0, 1.5, 0))
		cf = CFrame.new(base) * rotOnly(oh.CFrame) * CFrame.new(0, 1.55, 0)

	elseif a == "sword" then
		local hp = handPosOf(S.attachTarget) or oh.Position
		cf = CFrame.new(hp) * rotOnly(oh.CFrame) * CFrame.Angles(math.rad(-55), 0, 0)
			* CFrame.Angles(0, math.rad(90), 0) * CFrame.new(0, 3, 0)

	elseif a == "vest" then
		local wob = Vector3.new(math.sin(now * 7) * 0.035, math.sin(now * 5.3) * 0.03, math.cos(now * 6.1) * 0.035)
		cf = oh.CFrame * CFrame.new(wob + Vector3.new(0, -1.35, 0.35))

	elseif a == "carpet" then
		local ohum = ochar:FindFirstChildOfClass("Humanoid")
		local offs = 3
		if ohum and ohum.RigType == Enum.HumanoidRigType.R15 then offs = ohum.HipHeight + oh.Size.Y / 2 end
		local feetY = oh.Position.Y - offs
		local rp = RaycastParams.new()
		rp.FilterType = Enum.RaycastFilterType.Exclude
		rp.FilterDescendantsInstances = { char, ochar, Workspace.CurrentCamera }
		local hit = Workspace:Raycast(oh.Position, Vector3.new(0, -500, 0), rp)
		local floorY = hit and hit.Position.Y or -1e9
		if S.carpetY == nil then S.carpetY = math.max(floorY + 1.05, feetY - 0.3) end
		local vel = oh.AssemblyLinearVelocity
		local rising = vel.Y > 2 and (not ohum or ohum.FloorMaterial == Enum.Material.Air)
		if rising then
			S.carpetY = math.max(S.carpetY, feetY - 0.35)
		else
			S.carpetY = S.carpetY - CONFIG.CarpetSinkSpeed * dt
		end
		S.carpetY = math.min(S.carpetY, feetY + 0.15)
		S.carpetY = math.max(S.carpetY, floorY + 1.05)
		local ping = clampNum(LocalPlayer:GetNetworkPing(), 0.03, 0.35)
		local px = oh.Position + flat(vel) * ping
		cf = CFrame.new(px.X, S.carpetY - 0.55, px.Z) * rotOnly(oh.CFrame) * CFrame.Angles(math.rad(90), 0, 0)

	elseif a == "stand" then
		local bob = math.sin(now * 2.2) * 0.35
		local goal = oh.CFrame * CFrame.new(2.1, 1.7 + bob, 3.3)
		if (goal.Position - hrp.Position).Magnitude > 40 then
			cf = goal
		else
			cf = hrp.CFrame:Lerp(goal, 1 - math.exp(-9 * dt))
		end

	elseif a == "speedboost" then
		local fv = flat(oh.AssemblyLinearVelocity)
		local look = flat(oh.CFrame.LookVector)
		local pushing = fv.Magnitude > 2 and look.Magnitude > 0.01 and fv.Unit:Dot(look.Unit) > 0.3
		cf = oh.CFrame * CFrame.new(0, 0, pushing and 1.2 or 1.7)
		if pushing then velOut = look.Unit * (fv.Magnitude + CONFIG.SpeedBoostExtra) end

	elseif a == "orbit" then
		S.orbitAngle = S.orbitAngle + S.orbitSpeed * dt
		local r = S.orbitRadius
		local pos = oh.Position + Vector3.new(math.cos(S.orbitAngle) * r, 0, math.sin(S.orbitAngle) * r)
		cf = CFrame.lookAt(pos, Vector3.new(oh.Position.X, pos.Y, oh.Position.Z))

	elseif a == "kneel" then
		if now > S.attachUntil then
			stopAttach()
			return
		end
		if not S.kneelPos or flat(oh.Position - S.kneelPos).Magnitude > 12 then
			local p = oh.Position + flat(oh.CFrame.LookVector) * 3.4
			local gy = groundBelow(p, char, ochar) or (oh.Position.Y - 3)
			S.kneelPos = Vector3.new(p.X, gy, p.Z)
		end
		local pos = Vector3.new(S.kneelPos.X, S.kneelPos.Y + standHeight(hum, hrp) - 1.0, S.kneelPos.Z)
		cf = CFrame.lookAt(pos, Vector3.new(oh.Position.X, pos.Y, oh.Position.Z))

	elseif a == "kiss" then
		if now > S.attachUntil then
			stopAttach()
			return
		end
		local goal = oh.CFrame * CFrame.new(0, 0, -1.55) * CFrame.Angles(0, math.pi, 0)
		local k = clampNum((now - S.attachT0) / 0.6, 0, 1)
		local head, ohead = char:FindFirstChild("Head"), ochar:FindFirstChild("Head")
		if k >= 1 and head and ohead then
			goal = goal + Vector3.new(0, clampNum(ohead.Position.Y - head.Position.Y, -1.5, 1.5) * 0.85, 0)
		end
		cf = (S.attachStartCF and k < 1) and S.attachStartCF:Lerp(goal, smooth(k)) or goal
		if not S.kissHearts and now - S.attachT0 > 1.9 and ohead then
			S.kissHearts = true
			for i = 1, 4 do
				task.delay(i * 0.25, function()
					popText(ohead, "\226\153\165", Color3.fromRGB(255, 90, 140), Enum.Font.SourceSansBold)
				end)
			end
		end

	elseif a == "starplat" then
		if now > S.attachUntil then
			local back = S.spReturn
			stopAttach()
			sendChat("ORAAAAAA!")
			if back then hrp.CFrame = back end
			return
		end
		local tr = S.spTarget and hrpOf(S.spTarget)
		local base = tr and tr.Position or S.spFixed
		if not base then
			stopAttach()
			return
		end
		local away = flat(oh.Position - base)
		if away.Magnitude < 0.5 then away = flat(-oh.CFrame.LookVector) end
		if away.Magnitude < 0.01 then away = Vector3.new(0, 0, 1) end
		local pos = base + away.Unit * 3 + Vector3.new(math.random(-8, 8) / 50, 0, math.random(-8, 8) / 50)
		cf = CFrame.lookAt(pos, Vector3.new(base.X, pos.Y, base.Z))
		if now - S.spLastPop > 0.18 then
			S.spLastPop = now
			popText(tr or hrp, "ORA!", Color3.fromRGB(130, 90, 255))
		end
	end

	if cf then
		if S.spin and a ~= "carpet" then cf = cf * CFrame.Angles(0, S.spinAngle, 0) end
		hrp.CFrame = cf
		hrp.AssemblyLinearVelocity = velOut
		hrp.AssemblyAngularVelocity = Vector3.zero
	end
end

----------------------------------------------------------------------
-- Leash (client-visible verlet rope + collar, drags me when taut)
----------------------------------------------------------------------
local leashObj = nil

local function neckInfo(char)
	local head = char and char:FindFirstChild("Head")
	if not head then return nil end
	local neckCF = head.CFrame * CFrame.new(0, -0.6, 0)
	return neckCF, (neckCF * CFrame.new(0, 0, -0.62)).Position
end

local function leashCreate()
	if leashObj then return end
	local folder = Instance.new("Folder")
	folder.Name = "ServantLeash"
	folder.Parent = Workspace.CurrentCamera
	local function mk(size, color, shape)
		local p = Instance.new("Part")
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.CastShadow = false
		p.Material = Enum.Material.Metal
		p.Color = color
		if shape then p.Shape = shape end
		p.Size = size
		p.TopSurface = Enum.SurfaceType.Smooth
		p.BottomSurface = Enum.SurfaceType.Smooth
		p.Parent = folder
		return p
	end
	local links = {}
	for i = 1, CONFIG.LeashSegments do
		links[i] = mk(Vector3.new(0.2, 0.07, 0.5),
			(i % 2 == 0) and Color3.fromRGB(175, 175, 182) or Color3.fromRGB(120, 120, 128))
	end
	local collar = mk(Vector3.new(0.32, 1.1, 1.1), Color3.fromRGB(25, 25, 28), Enum.PartType.Cylinder)
	local ring = mk(Vector3.new(0.3, 0.3, 0.3), Color3.fromRGB(205, 205, 215), Enum.PartType.Ball)
	leashObj = { folder = folder, links = links, collar = collar, ring = ring, pts = nil }
end

local function leashDestroy()
	if leashObj then
		pcall(function() leashObj.folder:Destroy() end)
		leashObj = nil
	end
end

local function setLeash(on)
	S.leash = on
	if on then leashCreate() else leashDestroy() end
end

local function leashStep(dt)
	if not S.leash then return end
	if not leashObj or not leashObj.folder.Parent then
		leashObj = nil
		leashCreate()
	end
	local char = getChar()
	local hand = handPosOf(S.leashTarget)
	if not char or not hand then return end
	local neckCF, ringPos = neckInfo(char)
	if not neckCF then return end

	local n = CONFIG.LeashSegments
	local seg = CONFIG.LeashLength / n
	local pts = leashObj.pts
	if not pts then
		pts = {}
		for i = 0, n do
			local p = hand:Lerp(ringPos, i / n)
			pts[i + 1] = { p = p, o = p }
		end
		leashObj.pts = pts
	end
	dt = math.min(dt, 1 / 30)

	local g = Vector3.new(0, -Workspace.Gravity * 0.6, 0)
	if S.ud then g = Vector3.new(0, -196.2 * 0.6, 0) end
	for i = 2, n do
		local pt = pts[i]
		local vel = (pt.p - pt.o) * 0.985
		pt.o = pt.p
		pt.p = pt.p + vel + g * dt * dt
	end
	pts[1].p, pts[1].o = hand, hand
	pts[n + 1].p, pts[n + 1].o = ringPos, ringPos

	for _ = 1, 10 do
		for i = 1, n do
			local a, b = pts[i], pts[i + 1]
			local delta = b.p - a.p
			local d = delta.Magnitude
			if d > 1e-4 then
				local diff = (d - seg) / d
				if i == 1 then
					b.p = b.p - delta * diff
				elseif i == n then
					a.p = a.p + delta * diff
				else
					a.p = a.p + delta * diff * 0.5
					b.p = b.p - delta * diff * 0.5
				end
			end
		end
		pts[1].p = hand
		pts[n + 1].p = ringPos
	end

	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Exclude
	rp.FilterDescendantsInstances = { char, charOf(S.leashTarget) or char, Workspace.CurrentCamera }
	for i = 2, n do
		local pt = pts[i]
		local r = Workspace:Raycast(pt.p + Vector3.new(0, 1, 0), Vector3.new(0, -1.15, 0), rp)
		if r and pt.p.Y < r.Position.Y + 0.08 then
			pt.p = Vector3.new(pt.p.X, r.Position.Y + 0.08, pt.p.Z)
		end
	end

	for i = 1, n do
		local a, b = pts[i].p, pts[i + 1].p
		local dir = b - a
		local len = dir.Magnitude
		if len > 1e-3 then
			local l = leashObj.links[i]
			local up = (math.abs(dir.Unit.Y) > 0.98) and Vector3.new(1, 0, 0) or Vector3.new(0, 1, 0)
			if i % 2 == 1 then
				l.Size = Vector3.new(0.22, 0.07, len + 0.06)
			else
				l.Size = Vector3.new(0.07, 0.22, len + 0.06)
			end
			l.CFrame = CFrame.lookAt((a + b) / 2, b, up)
		end
	end
	leashObj.collar.CFrame = neckCF * CFrame.Angles(0, 0, math.rad(90))
	leashObj.ring.CFrame = CFrame.new(ringPos)
end

----------------------------------------------------------------------
-- Spin / freeze / speed / jump
----------------------------------------------------------------------
local function setSpin(on, v)
	S.spin = on
	if v then S.spinSpeed = v end
	local hum = getHum()
	if hum then hum.AutoRotate = not on and not S.mv.on and not S.mimic end
end

local function setFreeze(on)
	S.freeze = on
	if not on then
		local hrp = getHRP()
		if hrp then hrp.Anchored = false end
	end
end

----------------------------------------------------------------------
-- Walkfling, owner protection, security
----------------------------------------------------------------------
local function setWalkFling(on)
	if on == S.flinging then return end
	S.flinging = on
	if not on then return end
	task.spawn(function()
		while S.flinging do
			local hrp = getHRP()
			if hrp and hrp.Parent then
				local vel = hrp.AssemblyLinearVelocity
				hrp.AssemblyLinearVelocity = vel * 10000 + Vector3.new(0, 10000, 0)
				RunService.RenderStepped:Wait()
				if hrp.Parent then hrp.AssemblyLinearVelocity = vel end
				RunService.Stepped:Wait()
				if hrp.Parent then hrp.AssemblyLinearVelocity = vel + Vector3.new(0, 0.1, 0) end
			end
			RunService.Heartbeat:Wait()
		end
	end)
end

local function clearNC()
	for _, c in ipairs(S.ncList) do pcall(function() c:Destroy() end) end
	S.ncList, S.ncDone, S.ncMine = {}, {}, nil
end

-- my fling parts never collide with any of my owners
protectAuth = function()
	local char = getChar()
	if not char then return end
	if S.ncMine ~= char then
		clearNC()
		S.ncMine = char
	end
	local mine = {}
	for _, n in ipairs({ "HumanoidRootPart", "Head", "UpperTorso", "LowerTorso", "Torso" }) do
		local p = char:FindFirstChild(n)
		if p then mine[#mine + 1] = p end
	end
	eachAuth(function(uid)
		local oc = charOf(uid)
		if oc and not S.ncDone[oc] then
			S.ncDone[oc] = true
			for _, op in ipairs(oc:GetDescendants()) do
				if op:IsA("BasePart") then
					for _, mp in ipairs(mine) do
						local c = Instance.new("NoCollisionConstraint")
						c.Part0 = mp
						c.Part1 = op
						c.Parent = mp
						S.ncList[#S.ncList + 1] = c
					end
				end
			end
		end
	end)
end

local function endChase()
	S.chasing = false
	setWalkFling(false)
	setLock("security", false)
	clearNC()
end

local function nearestThreat()
	local oh = hrpOf(S.secTarget)
	if not oh then return nil end
	local best, bd = nil, CONFIG.SecurityRadius
	for _, p in ipairs(Players:GetPlayers()) do
		if p ~= LocalPlayer and not isAuth(p.UserId) and p.Character then
			local r = p.Character:FindFirstChild("HumanoidRootPart")
			local h = p.Character:FindFirstChildOfClass("Humanoid")
			if r and h and h.Health > 0 then
				local d = (r.Position - oh.Position).Magnitude
				if d < bd then best, bd = r, d end
			end
		end
	end
	return best
end

local function securityLoop(gen)
	local lastPos, stuckT = nil, 0
	while S.security and S.secGen == gen do
		local hrp, hum = getHRP(), getHum()
		local a = S.attach
		local blocked = a ~= nil and a ~= "follow" and not (a == "grab" and S.grabPhase == "armed")
		local busy = blocked or S.fly or S.ud or S.mimic or S.mv.on
		local threat = (hrp and hum and hum.Health > 0 and not busy) and nearestThreat() or nil
		if threat then
			if not S.chasing then
				S.chasing = true
				setLock("security", true)
			end
			protectAuth()
			setWalkFling(true)
			hum:MoveTo(threat.Position + flat(threat.AssemblyLinearVelocity) * 0.15)
			if lastPos and (hrp.Position - lastPos).Magnitude < 0.4 then
				stuckT = stuckT + 0.1
				if stuckT > 1 then
					hum.Jump = true
					stuckT = 0
				end
			else
				stuckT = 0
			end
			lastPos = hrp.Position
		elseif S.chasing then
			endChase()
			if hrp and hum then hum:MoveTo(hrp.Position) end
			lastPos, stuckT = nil, 0
		end
		task.wait(0.1)
	end
end

local function setSecurity(on, uid)
	if on and uid then S.secTarget = uid end
	if on == S.security then return end
	S.security = on
	S.secGen = S.secGen + 1
	if on then
		local gen = S.secGen
		task.spawn(function() securityLoop(gen) end)
	else
		endChase()
	end
end

----------------------------------------------------------------------
-- Follow (pathfinding, controls locked)
----------------------------------------------------------------------
local function startFollow(uid)
	beginAttach("follow", uid)
	setLock("follow", true)
	local gen = S.attachGen
	task.spawn(function()
		local path = PathfindingService:CreatePath({
			AgentRadius = 2, AgentHeight = 5, AgentCanJump = true, AgentCanClimb = true,
		})
		local waypoints, idx = {}, 1
		local lastTarget, lastCompute = nil, 0
		local lastPos, stuckT = nil, 0
		while S.attach == "follow" and S.attachGen == gen do
			local hrp, hum, oh = getHRP(), getHum(), hrpOf(S.attachTarget)
			if hrp and hum and oh and hum.Health > 0 and not S.chasing then
				local target = oh.Position
				if (target - hrp.Position).Magnitude < 6 then
					hum:MoveTo(hrp.Position)
					waypoints, lastTarget, stuckT = {}, nil, 0
				else
					local need = (not lastTarget) or (lastTarget - target).Magnitude > 6
						or (os.clock() - lastCompute) > 2.5
					if need then
						lastTarget, lastCompute = target, os.clock()
						local ok = pcall(function() path:ComputeAsync(hrp.Position, target) end)
						if ok and path.Status == Enum.PathStatus.Success then
							waypoints = path:GetWaypoints()
							idx = 2
						else
							waypoints = {}
						end
					end
					if #waypoints > 0 and waypoints[idx] then
						local wp = waypoints[idx]
						if flat(wp.Position - hrp.Position).Magnitude < 3.5 and idx < #waypoints then
							idx = idx + 1
							wp = waypoints[idx]
						end
						hum:MoveTo(wp.Position)
						if wp.Action == Enum.PathWaypointAction.Jump then hum.Jump = true end
					else
						hum:MoveTo(target)
					end
					if lastPos and (hrp.Position - lastPos).Magnitude < 0.4 then
						stuckT = stuckT + 0.1
						if stuckT > 1.2 then
							hum.Jump = true
							stuckT = 0
						end
					else
						stuckT = 0
					end
					lastPos = hrp.Position
				end
			end
			task.wait(0.1)
		end
	end)
end

----------------------------------------------------------------------
-- Upside-down gravity + flipped camera
----------------------------------------------------------------------
local function udAnim(hum, moving, speed)
	if not S.udTracks then
		S.udTracks = {}
		local r15 = hum.RigType == Enum.HumanoidRigType.R15
		S.udTracks.idle = loadTrack(r15 and "507766666" or "180435571")
		S.udTracks.walk = loadTrack(r15 and "507777826" or "180426354")
		for _, t in pairs(S.udTracks) do
			t.Looped = true
			t.Priority = Enum.AnimationPriority.Movement
		end
	end
	local w, i = S.udTracks.walk, S.udTracks.idle
	if moving then
		if i and i.IsPlaying then i:Stop(0.15) end
		if w then
			if not w.IsPlaying then w:Play(0.15) end
			w:AdjustSpeed(clampNum(speed / 14, 0.4, 3))
		end
	else
		if w and w.IsPlaying then w:Stop(0.15) end
		if i and not i.IsPlaying then i:Play(0.15) end
	end
end

local function udStopTracks()
	if S.udTracks then
		for _, t in pairs(S.udTracks) do pcall(function() t:Stop(0.1) end) end
		S.udTracks = nil
	end
end

setUpside = function(on)
	if on == S.ud then return end
	local cam = Workspace.CurrentCamera
	local hrp = getHRP()
	if on then
		if not hrp then return end
		S.ud = true
		stopAttach()
		clearMove()
		S.udGravity = Workspace.Gravity > 1 and Workspace.Gravity or 196.2
		Workspace.Gravity = 0
		S.udVy = 0
		S.udFace = nil
		local look = cam.CFrame.LookVector
		S.udYaw = math.atan2(-look.X, -look.Z)
		S.udPitch = math.asin(clampNum(look.Y, -1, 1))
		S.udDist = clampNum((cam.CFrame.Position - hrp.Position).Magnitude, 4, 40)
		cam.CameraType = Enum.CameraType.Scriptable
	else
		S.ud = false
		Workspace.Gravity = S.udGravity or 196.2
		cam.CameraType = Enum.CameraType.Custom
		udStopTracks()
		if hrp then
			local _, y = hrp.CFrame:ToEulerAnglesYXZ()
			hrp.CFrame = CFrame.new(hrp.Position + Vector3.new(0, 3, 0)) * CFrame.Angles(0, y, 0)
			hrp.AssemblyLinearVelocity = Vector3.zero
		end
	end
end

local function udStep(char, hrp, hum, dt)
	local stand = standHeight(hum, hrp)
	local lf = Vector3.new(-math.sin(S.udYaw), 0, -math.cos(S.udYaw))
	local rf = lf:Cross(Vector3.new(0, 1, 0))
	local dir = Vector3.zero
	local mvv = controlsObj and controlsObj:GetMoveVector() or Vector3.zero
	if mvv.Magnitude > 0.05 then
		dir = lf * (-mvv.Z) - rf * mvv.X -- camera is rolled 180: screen-right is world-left
	elseif hum.MoveDirection.Magnitude > 0.05 then
		dir = hum.MoveDirection
		if not controlsObj and not S.mv.on and next(S.locks) == nil then
			dir = lf * dir:Dot(lf) - rf * dir:Dot(rf)
		end
	end
	if dir.Magnitude > 1 then dir = dir.Unit end
	local yaw = S.udFace or S.udYaw
	if dir.Magnitude > 0.1 then
		yaw = math.atan2(-dir.X, -dir.Z)
		S.udFace = yaw
	end
	local hv = dir * hum.WalkSpeed
	local vy = clampNum(S.udVy + (S.udGravity or 196.2) * dt, -400, 300)
	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Exclude
	rp.FilterDescendantsInstances = { char, Workspace.CurrentCamera }
	local len = stand + 0.6 + math.abs(vy) * dt * 1.5
	local hit = Workspace:Raycast(hrp.Position, Vector3.new(0, len, 0), rp)
	local y = hrp.Position.Y
	local grounded = false
	if hit and vy >= 0 and (hit.Position.Y - y) <= stand + 0.2 + vy * dt then
		grounded = true
		vy = 0
		y = hit.Position.Y - stand
	end
	local wantJump = hum.Jump or (not UserInputService:GetFocusedTextBox() and UserInputService:IsKeyDown(Enum.KeyCode.Space))
	if grounded and wantJump and next(S.locks) == nil then
		vy = -hum.JumpPower
		grounded = false
	end
	hum.Jump = false
	S.udVy = vy
	hrp.CFrame = CFrame.new(hrp.Position.X, y, hrp.Position.Z) * CFrame.Angles(0, yaw, 0) * CFrame.Angles(0, 0, math.pi)
	hrp.AssemblyLinearVelocity = Vector3.new(hv.X, vy, hv.Z)
	hrp.AssemblyAngularVelocity = Vector3.zero
	udAnim(hum, grounded and dir.Magnitude > 0.1, hum.WalkSpeed)
end

local function udCamStep()
	if not S.ud then return end
	local char = getChar()
	local head = char and char:FindFirstChild("Head")
	if not head then return end
	local cam = Workspace.CurrentCamera
	if cam.CameraType ~= Enum.CameraType.Scriptable then cam.CameraType = Enum.CameraType.Scriptable end
	local rot = CFrame.Angles(0, S.udYaw, 0) * CFrame.Angles(S.udPitch, 0, 0) * CFrame.Angles(0, 0, math.pi)
	local focus = head.Position
	local pos = focus - rot.LookVector * S.udDist
	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Exclude
	rp.FilterDescendantsInstances = { char }
	local hit = Workspace:Raycast(focus, pos - focus, rp)
	if hit then pos = hit.Position + rot.LookVector * 0.4 end
	cam.CFrame = CFrame.new(pos) * rot
	cam.Focus = CFrame.new(focus)
end

track(UserInputService.InputChanged:Connect(function(input, processed)
	if not S.ud then return end
	local t = input.UserInputType
	if t == Enum.UserInputType.MouseMovement then
		if UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton2)
			or UserInputService.MouseBehavior == Enum.MouseBehavior.LockCenter then
			S.udYaw = S.udYaw + input.Delta.X * 0.0045
			S.udPitch = clampNum(S.udPitch + input.Delta.Y * 0.0045, -1.45, 1.45)
		end
	elseif t == Enum.UserInputType.Touch then
		if not processed then
			S.udYaw = S.udYaw + input.Delta.X * 0.006
			S.udPitch = clampNum(S.udPitch + input.Delta.Y * 0.006, -1.45, 1.45)
		end
	elseif t == Enum.UserInputType.MouseWheel then
		S.udDist = clampNum(S.udDist - input.Position.Z * 2, 3, 60)
	end
end))

----------------------------------------------------------------------
-- One-shot actions
----------------------------------------------------------------------
local function doThrow(power)
	if not (S.attach == "grab" and S.grabPhase == "held") then
		notify("Throw only works while I'm grabbed and held in front of the owner.")
		return
	end
	local oh, hrp = hrpOf(S.attachTarget), getHRP()
	if not (oh and hrp) then return end
	local look = oh.CFrame.LookVector
	stopAttach()
	S.limpUntil = os.clock() + 1.6
	S.noclipUntil = os.clock() + 0.35
	hrp.CFrame = oh.CFrame * CFrame.new(0, 0.8, -3.5)
	local vel = look * power + Vector3.new(0, power * 0.55, 0)
	task.spawn(function()
		for _ = 1, 8 do
			if hrp.Parent then hrp.AssemblyLinearVelocity = vel end
			RunService.Heartbeat:Wait()
		end
	end)
end

local function resetActivities()
	stopAttach()
	setFly(false)
	clearMove()
	stopMimic()
	setUpside(false)
	S.flingGen = S.flingGen + 1
end

local function flingSelf(power)
	local hrp = getHRP()
	if not hrp then return end
	resetActivities()
	local ang = math.random() * math.pi * 2
	local dir = Vector3.new(math.cos(ang), 0.55, math.sin(ang)).Unit
	S.limpUntil = os.clock() + 2.5
	task.spawn(function()
		for _ = 1, 12 do
			if hrp.Parent then
				hrp.AssemblyLinearVelocity = dir * power
				hrp.AssemblyAngularVelocity = Vector3.new(math.random(-30, 30), math.random(-30, 30), math.random(-30, 30))
			end
			RunService.Heartbeat:Wait()
		end
	end)
end

-- Fling another player: stick to them with huge spin, then return to where I was
local function flingPlayer(target)
	local hrp = getHRP()
	if not hrp then return end
	resetActivities()
	setFreeze(false)
	S.flingGen = S.flingGen + 1
	local gen = S.flingGen
	local startCF = hrp.CFrame
	S.limpUntil = os.clock() + 6
	local tp = target.Character and target.Character:FindFirstChild("HumanoidRootPart")
	local startPos = tp and tp.Position
	task.spawn(function()
		local t0, flip = os.clock(), 1
		while S.flingGen == gen and os.clock() - t0 < 3.5 do
			local h = getHRP()
			local th = target.Character and target.Character:FindFirstChild("HumanoidRootPart")
			if not (h and th and h.Parent and startPos) then break end
			if (th.Position - startPos).Magnitude > 80 or th.AssemblyLinearVelocity.Magnitude > 400 then break end
			protectAuth()
			flip = -flip
			h.CFrame = CFrame.new(th.Position + th.AssemblyLinearVelocity * 0.1 + Vector3.new(0, flip * 1.2, 0))
			h.AssemblyLinearVelocity = Vector3.new(9e5, 9e5, 9e5) * flip
			h.AssemblyAngularVelocity = Vector3.new(9e5, 9e5, 9e5)
			RunService.Heartbeat:Wait()
		end
		for _ = 1, 12 do
			local h = getHRP()
			if h then
				h.AssemblyLinearVelocity = Vector3.zero
				h.AssemblyAngularVelocity = Vector3.zero
				if S.flingGen == gen then h.CFrame = startCF end
			end
			RunService.Heartbeat:Wait()
		end
		if S.flingGen == gen and not S.chasing then clearNC() end
		S.limpUntil = os.clock() + 0.2
	end)
end

local function placeAt(cf)
	local hrp = getHRP()
	if not hrp then return end
	if S.attach and S.attach ~= "follow" then stopAttach() end
	hrp.CFrame = cf
	hrp.AssemblyLinearVelocity = Vector3.zero
end

local function bring(who)
	local oh = hrpOf(who.UserId)
	if not oh then return end
	local pos = oh.Position + flat(oh.CFrame.LookVector) * 4
	placeAt(CFrame.lookAt(pos, Vector3.new(oh.Position.X, pos.Y, oh.Position.Z)))
end

local function gotoPlayer(p)
	local th = p.Character and p.Character:FindFirstChild("HumanoidRootPart")
	if not th then return end
	local pos = (th.CFrame * CFrame.new(3, 0, 0)).Position
	placeAt(CFrame.lookAt(pos, Vector3.new(th.Position.X, pos.Y, th.Position.Z)))
end

local function praise(who)
	local name = who.DisplayName
	local lines = {
		"Thank you so much, " .. name .. "! :3",
		"Yes " .. name .. ", I'll keep doing my best!",
		"Aww, you're too kind, " .. name .. "!",
		"Thanks " .. name .. "! I'll work even harder!",
	}
	sendChat(lines[math.random(#lines)])
	playTemp(isR15() and "507770677" or "129423030", 3)
end

-- Star Platinum: the target is whoever the commander is facing
local function findFacingTarget(who)
	local oh = hrpOf(who.UserId)
	if not oh then return nil end
	local look = flat(oh.CFrame.LookVector)
	if look.Magnitude < 0.01 then return nil end
	look = look.Unit
	local best, bs = nil, math.huge
	for _, p in ipairs(Players:GetPlayers()) do
		if p ~= LocalPlayer and p ~= who and p.Character then
			local r = p.Character:FindFirstChild("HumanoidRootPart")
			local h = p.Character:FindFirstChildOfClass("Humanoid")
			if r and h and h.Health > 0 then
				local d = flat(r.Position - oh.Position)
				local dist = d.Magnitude
				if dist > 0.5 and dist < 100 then
					local ang = math.deg(math.acos(clampNum(look:Dot(d.Unit), -1, 1)))
					if ang < 28 then
						local score = ang * 2 + dist * 0.2
						if score < bs then best, bs = p, score end
					end
				end
			end
		end
	end
	return best
end

local function startStarPlatinum(who)
	local oh, hrp = hrpOf(who.UserId), getHRP()
	if not (oh and hrp) then return end
	local tgt = findFacingTarget(who)
	local ret = hrp.CFrame
	beginAttach("starplat", who.UserId)
	S.spReturn = ret
	S.spTarget = tgt and tgt.UserId or nil
	S.spFixed = oh.Position + flat(oh.CFrame.LookVector) * 7
	S.attachUntil = os.clock() + CONFIG.StarPlatinumTime
	sendChat("ORA ORA ORA ORA ORA ORA ORA!")
end

----------------------------------------------------------------------
-- .cmds and .help
----------------------------------------------------------------------
local CMD_LINES = {
	"Commands: .say .headsit .fly .unfly .grab .ungrab .throw .dance .undance .spin .unspin .freeze .unfreeze .mute .unmute",
	".fling .follow .unfollow .bring .goto .security .nosecurity .carpet .nocarpet .praise .speed .jp .sword .unsword .vest .unvest",
	".leash .unleash .stand .unstand .starplatinum .speedboost .nospeedboost .orbit .unorbit .upsidedown .noupsidedown .kneel .kiss",
	".mforward .mbackward .mleft .mright .mjump .stop .mimic .unmimic .owner .unowner .ownertransfer .normal .help <cmd>",
}
local function showCommands()
	task.spawn(function()
		for _, line in ipairs(CMD_LINES) do
			sendChat(line)
			task.wait(1.6)
		end
	end)
end

local HELP = {
	say = ".say <text> - I say <text> in chat. Nothing to undo.",
	headsit = ".headsit - I sit on your head. Undo: .normal (starting another attach command replaces it).",
	fly = ".fly [speed] - I can fly (default 60, range 5-500) with my own controls. Undo: .unfly",
	grab = ".grab - I sit down; walk up to me while facing me and I get held in front of you. Undo: .ungrab",
	throw = ".throw [power] - throws me forward while I'm held (needs .grab first). Default power 120.",
	dance = ".dance - I play a random Roblox catalog emote. Undo: .undance",
	spin = ".spin [speed] - I spin (default 20, negative = other direction). Undo: .unspin",
	freeze = ".freeze - I freeze in place. Undo: .unfreeze",
	cmds = ".cmds (or .commands) - I list every command in chat. Use .help <cmd> for details on one.",
	mute = ".mute - my chat is blocked and my chat box is covered. Undo: .unmute",
	fling = ".fling [strength] flings me. .fling <player> makes me fling that player. Undo: .normal / it ends by itself.",
	follow = ".follow - I pathfind to you and my own controls are locked. Undo: .unfollow",
	bring = ".bring - I teleport to you.",
	["goto"] = ".goto <player> - I teleport to that player (full name or just the start of it).",
	security = ".security - I walkfling anyone who gets near you (never owners) and stop when they leave. Undo: .nosecurity",
	carpet = ".carpet - I become your flying carpet: jump to go up, I slowly sink otherwise. Undo: .nocarpet",
	praise = ".praise - I thank you in chat and cheer.",
	speed = ".speed <n> - sets my walk speed (0-500). Reset with .speed 16 or .normal",
	jumppower = ".jumppower <n> (or .jp) - sets my jump power (0-1000). Reset with .jp 50 or .normal",
	sword = ".sword - I'm held in your right hand like a sword. Undo: .unsword",
	vest = ".vest - I hide inside your torso as a vest and can't touch you. Undo: .unvest",
	leash = ".leash - a chain leash from my neck to your hand; I get dragged when it's tight. Undo: .unleash",
	stand = ".stand - I float behind you like a JoJo stand. Undo: .unstand",
	starplatinum = ".starplatinum - I barrage whoever you are facing with ORA punches for a few seconds. Ends alone; .normal cancels.",
	speedboost = ".speedboost - I hold your back and push you forward for a small speed boost. Undo: .nospeedboost",
	orbit = ".orbit [speed] [radius] - I orbit you (default 2.5 and 7; negative speed = reverse). Undo: .unorbit",
	upsidedown = ".upsidedown - my gravity and camera flip; I walk on ceilings (or float up if none). Undo: .noupsidedown",
	mforward = ".mforward [seconds] - I walk forward until you say stop or .stop (or until [seconds] pass).",
	mbackward = ".mbackward [seconds] - I walk backward until you say stop or .stop (or until [seconds] pass).",
	mright = ".mright [f|b|degrees] - I steer right. f/b = also walk forward/back, a number = turn that many degrees. Stop: .stop",
	mleft = ".mleft [f|b|degrees] - I steer left. f/b = also walk forward/back, a number = turn that many degrees. Stop: .stop",
	mjump = ".mjump [loop|n] - I jump once, keep jumping (loop) or jump n times. Stop: stop / .stop",
	stop = ".stop (or just say 'stop') - ends .mforward .mbackward .mleft .mright and .mjump.",
	kneel = ".kneel - I kneel in front of you for 10 seconds. Undo: .normal",
	mimic = ".mimic - I copy your movement and animations; I can't move myself. Undo: .unmimic",
	kiss = ".kiss - I give you a short, sweet kiss animation. Ends by itself; .normal cancels.",
	owner = ".owner <player> - lets that player command me too; 'owner' targets then follow whoever said the command. Main owner only. Undo: .unowner",
	ownertransfer = ".ownertransfer <player> - hands main ownership to that player and you lose control. Main owner only.",
	normal = ".normal - stops everything and resets speed, jump power, mute and more.",
	help = ".help [cmd] - explains how a command works, its variants and how to undo it.",
}
local HELP_ALIAS = {
	unfly = "fly", ungrab = "grab", undance = "dance", unspin = "spin", unfreeze = "freeze",
	unmute = "mute", unfollow = "follow", nosecurity = "security", nocarpet = "carpet",
	unsword = "sword", unvest = "vest", unleash = "leash", unstand = "stand",
	nospeedboost = "speedboost", unorbit = "orbit", noupsidedown = "upsidedown",
	unmimic = "mimic", unowner = "owner", unkneel = "kneel", commands = "cmds", jp = "jumppower",
	ws = "speed",
}
local function showHelp(name)
	name = trim(name):lower():gsub("^%" .. CONFIG.Prefix, "")
	if name == "" then
		showCommands()
		return
	end
	name = HELP_ALIAS[name] or name
	sendChat(HELP[name] or ("I don't know a command called ." .. name .. " - try .cmds"))
end

stopAll = function()
	resetActivities()
	setDance(false)
	setSpin(false)
	setFreeze(false)
	setMute(false)
	setSecurity(false)
	setLeash(false)
	clearPose()
	S.walkSpeed, S.jumpPower = nil, nil
	S.limpUntil, S.noclipUntil = 0, 0
	local hum = getHum()
	if hum then
		hum.WalkSpeed = orig.walk
		hum.UseJumpPower = orig.useJP
		hum.JumpPower = orig.jump
		hum.AutoRotate = true
	end
	S.locks = {}
	applyLock()
end

----------------------------------------------------------------------
-- Per-frame update (before physics)
----------------------------------------------------------------------
local function update(dt)
	local char, hrp, hum = getChar(), getHRP(), getHum()
	if not (char and hrp and hum) or hum.Health <= 0 then return end
	local now = os.clock()
	if S.attach and not plrOf(S.attachTarget) then stopAttach() end
	local a = S.attach
	local cfMode = a ~= nil and a ~= "follow" and not (a == "grab" and S.grabPhase == "armed")

	if S.walkSpeed and hum.WalkSpeed ~= S.walkSpeed then hum.WalkSpeed = S.walkSpeed end
	if S.jumpPower then
		if not hum.UseJumpPower then hum.UseJumpPower = true end
		if hum.JumpPower ~= S.jumpPower then hum.JumpPower = S.jumpPower end
	end

	syncAnimate()

	local wantPS = S.fly or a == "sword" or a == "carpet" or now < S.limpUntil or S.ud
	if wantPS then
		if not hum.PlatformStand then hum.PlatformStand = true end
		S.psApplied = true
	elseif S.psApplied then
		hum.PlatformStand = false
		S.psApplied = false
	end

	if S.freeze and not hrp.Anchored then hrp.Anchored = true end

	if S.mimic then mimicStep(hrp, hum) end
	mvStep(hrp, hum, dt, now)

	if S.spin then
		local da = S.spinSpeed * dt
		S.spinAngle = (S.spinAngle + da) % (math.pi * 2)
		if not cfMode and not S.ud then hrp.CFrame = hrp.CFrame * CFrame.Angles(0, da, 0) end
	end

	if S.fly then flyStep(hrp, hum) end
	if S.ud then udStep(char, hrp, hum, dt) end

	attachStep(char, hrp, hum, dt, now)
	a = S.attach
	cfMode = a ~= nil and a ~= "follow" and not (a == "grab" and S.grabPhase == "armed")

	local noclip = a == "headsit" or a == "sword" or a == "vest" or a == "stand" or a == "orbit"
		or a == "kneel" or a == "kiss" or a == "starplat"
		or (a == "grab" and S.grabPhase == "held") or now < S.noclipUntil
	if noclip then
		for _, p in ipairs(parts) do
			if p.Parent and p.CanCollide then p.CanCollide = false end
		end
		if a == "vest" then
			for _, p in ipairs(parts) do
				if p.Parent and p.CanTouch then p.CanTouch = false end
			end
		end
	elseif a == "carpet" or a == "speedboost" then
		for _, n in ipairs({ "HumanoidRootPart", "Head", "UpperTorso", "LowerTorso", "Torso" }) do
			local p = char:FindFirstChild(n)
			if p and not p.CanCollide then p.CanCollide = true end
		end
	end

	if S.leash and not cfMode and not S.ud then
		local hand, head = handPosOf(S.leashTarget), char:FindFirstChild("Head")
		if hand and head then
			local ring = (head.CFrame * CFrame.new(0, -0.6, -0.62)).Position
			local d = hand - ring
			local dist = d.Magnitude
			if dist > CONFIG.LeashLength then
				hrp.CFrame = hrp.CFrame + d.Unit * (dist - CONFIG.LeashLength)
				local fd = flat(d)
				if fd.Magnitude > 0.5 and not S.fly and not S.mv.on and not S.mimic then hum:Move(fd.Unit, false) end
			end
		end
	end

	poseStep(dt)
end

----------------------------------------------------------------------
-- Owner system
----------------------------------------------------------------------
local refreshOwnerUI = function() end

local function setMainOwner(p)
	stopAll()
	S.ownerId = p.UserId
	S.ownerName = p.DisplayName
	S.co[p.UserId] = nil
	saveData()
	refreshOwnerUI()
	sendChat("I now serve " .. p.DisplayName)
end

local function releaseOwner()
	stopAll()
	S.ownerId, S.ownerName, S.co = nil, nil, {}
	saveData()
	refreshOwnerUI()
end

----------------------------------------------------------------------
-- Commands
----------------------------------------------------------------------
local COMMANDS = {}
local function reg(names, fn)
	for _, n in ipairs(names) do COMMANDS[n] = fn end
end
local function noPlayer() sendChat("I can't find that player.") end
local function isMain(who) return who.UserId == S.ownerId end

reg({ "say" }, function(_, raw) if raw ~= "" then sendChat(raw) end end)
reg({ "headsit" }, function(_, _, who) beginAttach("headsit", who.UserId) end)
reg({ "fly" }, function(args) setFly(true, toNum(args[1], S.flySpeed, 5, 500)) end)
reg({ "unfly" }, function() setFly(false) end)
reg({ "grab" }, function(_, _, who)
	beginAttach("grab", who.UserId)
	S.grabPhase = "armed"
	local hum = getHum()
	if hum then hum.Sit = true end
end)
reg({ "ungrab" }, function() if S.attach == "grab" then stopAttach() end end)
reg({ "throw" }, function(args) doThrow(toNum(args[1], CONFIG.DefaultThrow, 10, 800)) end)
reg({ "dance" }, function() setDance(true) end)
reg({ "undance" }, function() setDance(false) end)
reg({ "spin" }, function(args) setSpin(true, toNum(args[1], CONFIG.DefaultSpin, -500, 500)) end)
reg({ "unspin" }, function() setSpin(false) end)
reg({ "freeze" }, function() setFreeze(true) end)
reg({ "unfreeze" }, function() setFreeze(false) end)
reg({ "cmds", "commands" }, showCommands)
reg({ "help" }, function(_, raw) showHelp(raw) end)
reg({ "mute" }, function() setMute(true) end)
reg({ "unmute" }, function() setMute(false) end)
reg({ "fling" }, function(args, raw)
	local a1 = args[1]
	if a1 and tonumber(a1) == nil then
		local p = findPlayer(raw)
		if not p then return noPlayer() end
		if isAuth(p.UserId) then return sendChat("I can't fling one of my owners.") end
		flingPlayer(p)
	else
		flingSelf(toNum(a1, CONFIG.DefaultFling, 10, 3000))
	end
end)
reg({ "follow" }, function(_, _, who) startFollow(who.UserId) end)
reg({ "unfollow" }, function() if S.attach == "follow" then stopAttach() end end)
reg({ "bring" }, function(_, _, who) bring(who) end)
reg({ "goto" }, function(_, raw)
	local p = findPlayer(raw)
	if not p then return noPlayer() end
	gotoPlayer(p)
end)
reg({ "security" }, function(_, _, who) setSecurity(true, who.UserId) end)
reg({ "nosecurity" }, function() setSecurity(false) end)
reg({ "carpet" }, function(_, _, who) beginAttach("carpet", who.UserId) end)
reg({ "nocarpet" }, function() if S.attach == "carpet" then stopAttach() end end)
reg({ "praise" }, function(_, _, who) praise(who) end)
reg({ "speed", "ws" }, function(args)
	local v = tonumber(args[1])
	if v then S.walkSpeed = clampNum(v, 0, 500) end
end)
reg({ "jumppower", "jp" }, function(args)
	local v = tonumber(args[1])
	if v then S.jumpPower = clampNum(v, 0, 1000) end
end)
reg({ "sword" }, function(_, _, who) beginAttach("sword", who.UserId) end)
reg({ "unsword" }, function() if S.attach == "sword" then stopAttach() end end)
reg({ "normal" }, function() stopAll() end)
reg({ "vest" }, function(_, _, who) beginAttach("vest", who.UserId) end)
reg({ "unvest" }, function() if S.attach == "vest" then stopAttach() end end)
reg({ "leash" }, function(_, _, who)
	S.leashTarget = who.UserId
	setLeash(true)
end)
reg({ "unleash" }, function() setLeash(false) end)

-- v2 commands
reg({ "stand" }, function(_, _, who) beginAttach("stand", who.UserId) end)
reg({ "unstand" }, function() if S.attach == "stand" then stopAttach() end end)
reg({ "starplatinum" }, function(_, _, who) startStarPlatinum(who) end)
reg({ "speedboost" }, function(_, _, who) beginAttach("speedboost", who.UserId) end)
reg({ "nospeedboost" }, function() if S.attach == "speedboost" then stopAttach() end end)
reg({ "orbit" }, function(args, _, who)
	local oh, hrp = hrpOf(who.UserId), getHRP()
	beginAttach("orbit", who.UserId)
	S.orbitSpeed = toNum(args[1], CONFIG.OrbitSpeed, -30, 30)
	S.orbitRadius = toNum(args[2], CONFIG.OrbitRadius, 2, 60)
	if oh and hrp then S.orbitAngle = math.atan2(hrp.Position.Z - oh.Position.Z, hrp.Position.X - oh.Position.X) end
end)
reg({ "unorbit" }, function() if S.attach == "orbit" then stopAttach() end end)
reg({ "upsidedown" }, function() setUpside(true) end)
reg({ "noupsidedown" }, function() setUpside(false) end)
reg({ "kneel" }, function(_, _, who)
	beginAttach("kneel", who.UserId)
	S.attachUntil = os.clock() + CONFIG.KneelTime
end)
reg({ "unkneel" }, function() if S.attach == "kneel" then stopAttach() end end)
reg({ "kiss" }, function(_, _, who)
	beginAttach("kiss", who.UserId)
	S.kissHearts = false
	S.attachUntil = os.clock() + CONFIG.KissTime
end)
reg({ "mimic" }, function(_, _, who) startMimic(who.UserId) end)
reg({ "unmimic" }, function() stopMimic() end)

-- manual movement
local function moveTimed(dirv, args)
	if not ensureMove() then return end
	S.mv.dirv = dirv
	local secs = tonumber(args[1])
	S.mv.untilT = secs and (os.clock() + clampNum(secs, 0.1, 600)) or nil
end
reg({ "mforward", "mf" }, function(args) moveTimed(1, args) end)
reg({ "mbackward", "mb" }, function(args) moveTimed(-1, args) end)
local function steer(sign, args)
	if S.ud then return end
	if not ensureMove() then return end
	local v = (args[1] or ""):lower()
	local n = tonumber(v)
	if n then
		S.mv.heading = S.mv.heading + math.rad(n) * sign
	elseif v == "f" or v == "forward" then
		S.mv.dirv, S.mv.turn, S.mv.untilT = 1, sign, nil
	elseif v == "b" or v == "back" or v == "backward" then
		S.mv.dirv, S.mv.turn, S.mv.untilT = -1, sign, nil
	else
		S.mv.turn = sign
	end
end
reg({ "mright" }, function(args) steer(-1, args) end)
reg({ "mleft" }, function(args) steer(1, args) end)
reg({ "mjump" }, function(args)
	local hum = getHum()
	local v = (args[1] or ""):lower()
	if v == "" then
		if hum then hum.Jump = true end
	elseif v == "loop" or v == "l" or v == "auto" then
		if ensureMove() then S.mv.loop = true end
	elseif tonumber(v) then
		if ensureMove() then S.mv.jumps = clampNum(math.floor(tonumber(v)), 1, 100) end
	end
end)
reg({ "stop" }, function() clearMove() end)

-- owner management
reg({ "owner" }, function(_, raw, who)
	if not isMain(who) then return end
	local p = findPlayer(raw)
	if not p then return noPlayer() end
	if p.UserId == S.ownerId then return end
	S.co[p.UserId] = true
	saveData()
	notify(p.DisplayName .. " can now command you too.")
	sendChat(p.DisplayName .. " can command me too.")
end)
reg({ "unowner" }, function(_, raw, who)
	if not isMain(who) then return end
	local p = findPlayer(raw)
	if not p then return noPlayer() end
	if S.co[p.UserId] then
		S.co[p.UserId] = nil
		saveData()
		sendChat(p.DisplayName .. " can't command me anymore.")
	end
end)
reg({ "ownertransfer" }, function(_, raw, who)
	if not isMain(who) then return end
	local p = findPlayer(raw)
	if not p then return noPlayer() end
	if p.UserId == S.ownerId then return end
	setMainOwner(p)
end)

local lastKey, lastCmdT = nil, 0
local function onChat(plr, msg)
	if not isAuth(plr.UserId) then return end
	msg = trim(tostring(msg or ""))
	local lower = msg:lower()
	local cmd, rest
	if lower:match("^stop[%.!]*$") then
		cmd, rest = "stop", ""
	elseif msg:sub(1, #CONFIG.Prefix) == CONFIG.Prefix then
		cmd, rest = msg:sub(#CONFIG.Prefix + 1):match("^(%S+)%s*(.*)$")
	end
	if not cmd then return end
	local fn = COMMANDS[cmd:lower()]
	if not fn then return end
	local now, key = os.clock(), plr.UserId .. ":" .. msg
	if key == lastKey and now - lastCmdT < 0.6 then return end -- same line arrives from two chat events
	lastKey, lastCmdT = key, now
	rest = trim(rest)
	local args = {}
	for w in rest:gmatch("%S+") do args[#args + 1] = w end
	local ok, err = pcall(fn, args, rest, plr)
	if not ok then warn("[Servant] command error: " .. tostring(err)) end
end

local function hookPlayer(p)
	track(p.Chatted:Connect(function(m) onChat(p, m) end))
end
for _, p in ipairs(Players:GetPlayers()) do
	if p ~= LocalPlayer then hookPlayer(p) end
end
track(Players.PlayerAdded:Connect(hookPlayer))
pcall(function()
	track(TextChatService.MessageReceived:Connect(function(m)
		local src = m.TextSource
		if src then
			local p = Players:GetPlayerByUserId(src.UserId)
			if p and p ~= LocalPlayer then onChat(p, m.Text) end
		end
	end))
end)
track(Players.PlayerRemoving:Connect(function(p)
	if p.UserId == S.ownerId then
		notify("Your owner left the game.")
		stopAll()
	end
end))

----------------------------------------------------------------------
-- Character lifecycle + main loops
----------------------------------------------------------------------
local function onCharacter(char)
	task.spawn(function()
		local hum = char:WaitForChild("Humanoid", 10)
		local hrp = char:WaitForChild("HumanoidRootPart", 10)
		if not (hum and hrp) then return end
		rebuildParts(char)
		track(char.DescendantAdded:Connect(function(d)
			if d:IsA("BasePart") then parts[#parts + 1] = d end
		end))
		if S.walkSpeed == nil and S.jumpPower == nil then
			orig.walk, orig.jump, orig.useJP = hum.WalkSpeed, hum.JumpPower, hum.UseJumpPower
		end
		S.psApplied, S.animOff, S.pa = false, false, nil
		S.udTracks, S.mimicTracks = nil, {}
		S.ncList, S.ncDone, S.ncMine = {}, {}, nil
		if S.spin or S.mv.on or S.mimic then hum.AutoRotate = false end
		track(hum.Died:Connect(function()
			setWalkFling(false)
			if S.ud then setUpside(false) end
		end))
		if S.dancing then
			task.wait(1.2)
			if S.dancing then startDance() end
		end
	end)
end
if LocalPlayer.Character then onCharacter(LocalPlayer.Character) end
track(LocalPlayer.CharacterAdded:Connect(onCharacter))

track(RunService.Stepped:Connect(function(_, dt)
	local ok, err = pcall(update, dt)
	if not ok and not S.warned then
		S.warned = true
		warn("[Servant] " .. tostring(err))
	end
end))
track(RunService.RenderStepped:Connect(function(dt)
	pcall(leashStep, dt)
	pcall(udCamStep)
end))

local muteTimer = 0
track(RunService.Heartbeat:Connect(function(dt)
	muteTimer = muteTimer + dt
	if muteTimer > 0.5 then
		muteTimer = 0
		if S.muted then applyChatBlock(true) end
	end
end))

----------------------------------------------------------------------
-- GUI: draggable circle button + sliding textbox
----------------------------------------------------------------------
local gui = Instance.new("ScreenGui")
gui.Name = "Servant_" .. tostring(math.random(100000, 999999))
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.DisplayOrder = 2147483647
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

local vp = Workspace.CurrentCamera.ViewportSize
local holder = Instance.new("Frame")
holder.Name = "Holder"
holder.BackgroundTransparency = 1
holder.Size = UDim2.fromOffset(52, 52)
holder.Position = UDim2.fromOffset(math.max(0, vp.X - 80), vp.Y * 0.42)
holder.Parent = gui

local btn = Instance.new("TextButton")
btn.Name = "Toggle"
btn.Size = UDim2.fromScale(1, 1)
btn.BackgroundColor3 = Color3.fromRGB(110, 86, 230)
btn.AutoButtonColor = false
btn.Text = "S"
btn.TextColor3 = Color3.new(1, 1, 1)
btn.Font = Enum.Font.GothamBold
btn.TextSize = 24
btn.Parent = holder
Instance.new("UICorner", btn).CornerRadius = UDim.new(1, 0) -- perfect circle
local btnStroke = Instance.new("UIStroke")
btnStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
btnStroke.Color = Color3.fromRGB(255, 255, 255)
btnStroke.Transparency = 0.6
btnStroke.Thickness = 2
btnStroke.Parent = btn

local clip = Instance.new("Frame")
clip.Name = "Clip"
clip.BackgroundTransparency = 1
clip.ClipsDescendants = true
clip.AnchorPoint = Vector2.new(1, 0.5)
clip.Position = UDim2.new(0, -8, 0.5, 0)
clip.Size = UDim2.fromOffset(220, 42)
clip.Visible = false
clip.Parent = holder

local box = Instance.new("TextBox")
box.Name = "OwnerBox"
box.Size = UDim2.fromScale(1, 1)
box.Position = UDim2.fromScale(1, 0)
box.BackgroundColor3 = Color3.fromRGB(28, 28, 36)
box.TextColor3 = Color3.new(1, 1, 1)
box.PlaceholderText = "Owner name (e.g. war)"
box.PlaceholderColor3 = Color3.fromRGB(150, 150, 165)
box.Text = ""
box.ClearTextOnFocus = false
box.Font = Enum.Font.GothamMedium
box.TextSize = 16
box.TextXAlignment = Enum.TextXAlignment.Left
box.Parent = clip
Instance.new("UICorner", box).CornerRadius = UDim.new(0, 12)
local pad = Instance.new("UIPadding", box)
pad.PaddingLeft = UDim.new(0, 14)
pad.PaddingRight = UDim.new(0, 10)
local boxStroke = Instance.new("UIStroke")
boxStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
boxStroke.Color = Color3.fromRGB(110, 86, 230)
boxStroke.Thickness = 2
boxStroke.Parent = box

local open = false
local function setOpen(v)
	open = v
	if v then
		clip.Visible = true
		box.Position = UDim2.fromScale(1, 0)
		TweenService:Create(box, TweenInfo.new(0.28, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
			{ Position = UDim2.fromScale(0, 0) }):Play()
		if not UserInputService.TouchEnabled then
			task.delay(0.3, function() if open then box:CaptureFocus() end end)
		end
	else
		box:ReleaseFocus()
		local tw = TweenService:Create(box, TweenInfo.new(0.22, Enum.EasingStyle.Quint, Enum.EasingDirection.In),
			{ Position = UDim2.fromScale(1, 0) })
		tw:Play()
		tw.Completed:Connect(function() if not open then clip.Visible = false end end)
	end
end

local function flashStroke(color)
	boxStroke.Color = color
	task.delay(1, function() boxStroke.Color = Color3.fromRGB(110, 86, 230) end)
end

refreshOwnerUI = function()
	if S.ownerId then
		btn.BackgroundColor3 = Color3.fromRGB(60, 170, 100)
		local n = 0
		for _ in pairs(S.co) do n = n + 1 end
		local extra = n > 0 and (" +" .. n) or ""
		box.PlaceholderText = "Owner: " .. tostring(S.ownerName or S.ownerId) .. extra
	else
		btn.BackgroundColor3 = Color3.fromRGB(110, 86, 230)
		box.PlaceholderText = "Owner name (e.g. war)"
	end
end

box.FocusLost:Connect(function(enter)
	if not enter then return end
	local q = trim(box.Text)
	box.Text = ""
	if q == "" then
		if S.ownerId then
			releaseOwner()
			notify("Owner released. You're free.")
		end
		return
	end
	local p = findPlayer(q)
	if p then
		S.co = {} -- a fresh pick resets everyone the old owner had added
		setMainOwner(p)
		flashStroke(Color3.fromRGB(80, 220, 120))
		notify(p.DisplayName .. " (@" .. p.Name .. ") is now your owner. They can type .cmds in chat.")
		task.delay(0.9, function() setOpen(false) end)
	else
		box.PlaceholderText = "No player found for \"" .. q .. "\""
		flashStroke(Color3.fromRGB(235, 70, 80))
	end
end)

-- dragging (a tap without movement toggles the box)
local dragging, dragInput, dragStart, startPos, moved = false, nil, nil, nil, false
btn.InputBegan:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
		dragging, dragInput, moved = true, input, false
		dragStart = input.Position
		startPos = holder.AbsolutePosition
		local c
		c = input.Changed:Connect(function()
			if input.UserInputState == Enum.UserInputState.End then
				c:Disconnect()
				dragging = false
				if not moved then setOpen(not open) end
			end
		end)
	end
end)
track(UserInputService.InputChanged:Connect(function(input)
	if not dragging then return end
	if input.UserInputType == Enum.UserInputType.MouseMovement
		or (input.UserInputType == Enum.UserInputType.Touch and input == dragInput) then
		local d = input.Position - dragStart
		if d.Magnitude > 6 then moved = true end
		if moved then
			local v = Workspace.CurrentCamera.ViewportSize
			holder.Position = UDim2.fromOffset(
				clampNum(startPos.X + d.X, 0, v.X - 52),
				clampNum(startPos.Y + d.Y, 0, v.Y - 52))
		end
	end
end))

safeParent(gui)

----------------------------------------------------------------------
-- Restore saved owners, server-hop queue, cleanup
----------------------------------------------------------------------
loadData()
if S.ownerId then
	refreshOwnerUI()
	notify("Welcome back. Your owner is " .. tostring(S.ownerName or S.ownerId) .. ".")
else
	notify("Loaded. Tap the S button, type your owner's name and press Enter.")
end

local LOADER = table.concat({
	"repeat task.wait() until game:IsLoaded()",
	"local g = (getgenv and getgenv()) or _G",
	"if g.__ServantJob == game.JobId and g.__ServantCleanup then return end",
	"local ok, src = pcall(readfile, \"" .. CONFIG.ScriptFile .. "\")",
	"if ok and type(src) == \"string\" and #src > 0 then",
	"\tlocal fn, err = loadstring(src)",
	"\tif fn then task.spawn(fn) else warn(\"[Servant] \" .. tostring(err)) end",
	"end",
}, "\n")

local teleportQueued = false
track(LocalPlayer.OnTeleport:Connect(function()
	if teleportQueued then return end
	teleportQueued = true
	local q = queue_on_teleport or (syn and syn.queue_on_teleport) or (fluxus and fluxus.queue_on_teleport)
	if q and isfile and isfile(CONFIG.ScriptFile) then pcall(q, LOADER) end
end))

if isfile and not isfile(CONFIG.ScriptFile) then
	notify("Tip: save this script as " .. CONFIG.ScriptFile .. " in your executor's workspace folder so it can auto-run when you hop servers.")
end

env.__ServantCleanup = function()
	for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
	pcall(stopAll)
	pcall(clearNC)
	pcall(function() gui:Destroy() end)
	pcall(function() blockGui:Destroy() end)
	env.__ServantCleanup = nil
end

]==]
pcall(function() if writefile then writefile("ServantScript.lua", SRC) end end)
local fn, err = loadstring(SRC)
if not fn then
	banner("Servant COMPILE ERROR: " .. tostring(err), 200, 50, 60, 40)
	warn("[Servant] " .. tostring(err))
	return
end
task.spawn(function()
	local ok, e = xpcall(fn, function(m)
		return tostring(m) .. " | " .. tostring((debug and debug.traceback) and debug.traceback("", 2) or "")
	end)
	if not ok then
		banner("Servant ERROR: " .. tostring(e):sub(1, 450), 200, 50, 60, 40)
		warn("[Servant] " .. tostring(e))
	end
end)
