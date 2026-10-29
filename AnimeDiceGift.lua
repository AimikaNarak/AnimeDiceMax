-- Anime Dice · Trade Hub (Linggung)
-- Several sender accounts trade the items you pick to ONE receiver account.
--
-- Everything is set in the window and saved to workspace/AnimeDice/gift/plan.json, which every
-- screen on this PC reads, so you set it up once on any screen and all accounts follow:
--   Receiver tab  type the receiver's username, check the avatar/info, set it
--   Senders tab   add the sender usernames (list with avatars + live status)
--   Items tab     tick what to send and how many (or "Send everything")
--   Run tab       Start / Stop, progress of every sender, log
--
-- Trade protocol (from the game's own TradeService/TradeClass, dump 2026-10-30):
--   RequestTrade(player) → RespondToRequest(true) → ChangeOffer(key, n) → AdvanceTrade (ready)
--   → AdvanceTrade (accept) → 3s countdown → TradeEvent "Ended" { reason = "Completed" }
--   max 20 different entries per trade, stackables use their name as key, units their GUID,
--   both sides must stay within Unit Storage, AccountAge >= 14, Rolls >= 1000.
--   Private servers CAN trade since this update (the PrivateServerId check was removed).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local TeleportService = game:GetService("TeleportService")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")

local LP = Players.LocalPlayer
while not LP do
    task.wait()
    LP = Players.LocalPlayer
end
if not game:IsLoaded() then
    game.Loaded:Wait()
end

local K = {
    URL = "https://raw.githubusercontent.com/AimikaNarak/AnimeDiceMax/main/AnimeDiceGift.lua",
    DIR = "AnimeDice/gift",
    PLAN = "AnimeDice/gift/plan.json",
    FRESH = 60,            -- a status file older than this = that screen is offline
    MAX_ENTRIES = 20,      -- TradeConfig.MAX_UNIQUE_ENTRIES (re-read below)
}

-- single instance: a re-run replaces the old copy
local TOKEN = HttpService:GenerateGUID(false)
LP:SetAttribute("AnimeDiceGiftRun", TOKEN)
local function alive()
    return LP:GetAttribute("AnimeDiceGiftRun") == TOKEN
end

-- ── state ───────────────────────────────────────────────────
local S = {
    plan = {
        receiver = nil,      -- { name, userId, display }
        senders = {},        -- { { name, userId }, ... }
        rules = {},          -- [itemName] = number | "all"
        all = false,         -- send every tradeable entry
        running = false,
        wait = 60,           -- seconds in the same server before trading
        follow = false,      -- senders teleport to the receiver's server
        rev = 0,
    },
    planRev = -1,
    joinedAt = os.time(),
    role = "editor",         -- receiver | sender | editor
    phase = "idle",
    msg = "",
    sent = 0,
    remaining = 0,
    logLines = {},
    lastTp = 0,
    afk = "pending",
    statuses = {},           -- [lower name] = status file content
}

local function log(text, kind)
    local line = os.date("%H:%M:%S") .. " " .. tostring(text)
    print("[AnimeDiceGift] " .. line)
    table.insert(S.logLines, 1, { text = line, kind = kind })
    if #S.logLines > 40 then
        table.remove(S.logLines)
    end
end

local function asGame(fn, ...)
    if type(setthreadidentity) ~= "function" or type(getthreadidentity) ~= "function" then
        return fn(...)
    end
    local previous = getthreadidentity()
    setthreadidentity(2)
    local packed = table.pack(pcall(fn, ...))
    setthreadidentity(previous)
    if not packed[1] then
        error(packed[2], 0)
    end
    return table.unpack(packed, 2, packed.n)
end

-- ── game modules ────────────────────────────────────────────
local M = {}
do
    local fw = ReplicatedStorage:WaitForChild("Framework", 60)
    if not fw then
        error("[AnimeDiceGift] ReplicatedStorage.Framework not found - wrong game? PlaceId " .. game.PlaceId)
    end
    local t0 = os.clock()
    while not fw:GetAttribute("IsLoaded") and os.clock() - t0 < 60 do
        task.wait(0.5)
    end
    local F = fw:WaitForChild("Features", 30)
    local function req(inst, label)
        local ok, res = pcall(asGame, require, inst)
        if not ok then
            error("[AnimeDiceGift] require " .. label .. " failed: " .. tostring(res), 0)
        end
        return res
    end
    M.Data = req(F.Data.DataController, "DataController")
    M.Buff = req(F.Buffs.BuffController, "BuffController")
    M.Entry = req(F.Inventory.EntryRegistry, "EntryRegistry")
    M.TradeConfig = req(F.Trading.TradeConfig, "TradeConfig")
    M.NF = req(ReplicatedStorage.Packages.NumberFormatter, "NumberFormatter")
    M.Rarities = req(fw.Other.Rarities, "Rarities")
    local okIcon, icon = pcall(asGame, require, F.Inventory.EntryIcon)
    M.EntryIcon = okIcon and icon or nil
    if not okIcon then
        log("game icons unavailable (" .. tostring(icon) .. ") - using simple tiles", "Warn")
    end
    K.MAX_ENTRIES = M.TradeConfig.MAX_UNIQUE_ENTRIES or 20
end
local D = M.Data

-- ── remotes ─────────────────────────────────────────────────
local R = {}
do
    local svc = ReplicatedStorage:WaitForChild("Network", 30):WaitForChild("TradeService", 30)
    local re = svc:WaitForChild("RE", 10)
    for _, name in ipairs({ "RequestTrade", "RespondToRequest", "ChangeOffer", "AdvanceTrade",
        "CancelTrade", "SetTradeRequestsEnabled", "TradeEvent" }) do
        R[name] = re:WaitForChild(name, 10)
        if not R[name] then
            log("missing remote TradeService.RE." .. name, "Bad")
        end
    end
end

local function fire(r, ...)
    if r then
        r:FireServer(...)
    end
end

-- ── helpers ─────────────────────────────────────────────────
local H = {}

function H.fmt(n)
    local ok, s = pcall(M.NF.FormatCompact, n)
    return ok and s or tostring(n)
end

function H.lower(s)
    return string.lower(tostring(s or ""))
end

function H.storage()
    local n = 0
    for _, e in pairs(D.Inventory() or {}) do
        local cfg = M.Entry.getEntryConfig(e.name)
        if cfg and cfg.kind == "Unit" then
            n = n + 1
        end
    end
    local cap = 0
    pcall(function()
        cap = M.Buff.GetBuff("Unit Storage")
    end)
    return n, cap
end

function H.tradeable(e)
    local ok, res = pcall(M.TradeConfig.IsTradeable, e)
    return ok and res
end

-- inventory grouped by name: { name, cfg, kind, total, keys = { {key, amount, income} } }
function H.groups()
    local byName = {}
    local list = {}
    local plotted = {}
    for _, slot in pairs(D.Slots() or {}) do
        if type(slot) == "table" and slot.unitId then
            plotted[slot.unitId] = true
        end
    end
    for key, e in pairs(D.Inventory() or {}) do
        local cfg = M.Entry.getEntryConfig(e.name)
        if cfg and (e.amount or 0) > 0 and not plotted[key] then
            local g = byName[e.name]
            if not g then
                g = { name = e.name, cfg = cfg, kind = cfg.kind, total = 0, keys = {},
                    tradeable = H.tradeable(e) }
                byName[e.name] = g
                table.insert(list, g)
            end
            local income = 0
            if cfg.kind == "Unit" then
                local ok, inc = pcall(cfg.income, e.attributes or {})
                income = ok and inc or 0
            end
            g.total = g.total + (e.amount or 1)
            table.insert(g.keys, { key = key, amount = e.amount or 1, income = income })
        end
    end
    for _, g in ipairs(list) do
        table.sort(g.keys, function(a, b)
            return a.income > b.income
        end)
        local r = nil
        pcall(function()
            r = M.Rarities.Get(g.cfg.rarity)
        end)
        g.sort = (r and r.sortOrder or 0) * 1000 + (g.kind == "Unit" and 1 or 0)
    end
    table.sort(list, function(a, b)
        if a.sort ~= b.sort then
            return a.sort > b.sort
        end
        return a.name < b.name
    end)
    return list
end

-- what this account still has to send under the current plan: { {key, amount, unit, name} }
function H.toSend()
    local plan = S.plan
    local out = {}
    for _, g in ipairs(H.groups()) do
        if g.tradeable then
            local want = plan.all and "all" or plan.rules[g.name]
            if want then
                local left = (want == "all") and g.total or math.min(tonumber(want) or 0, g.total)
                for _, k in ipairs(g.keys) do
                    if left <= 0 then
                        break
                    end
                    local n = math.min(k.amount, left)
                    table.insert(out, { key = k.key, amount = n, unit = g.kind == "Unit", name = g.name })
                    left = left - n
                end
            end
        end
    end
    return out
end

function H.findPlayer(name)
    for _, p in ipairs(Players:GetPlayers()) do
        if H.lower(p.Name) == H.lower(name) then
            return p
        end
    end
    return nil
end

function H.isSender(name)
    for _, s in ipairs(S.plan.senders) do
        if H.lower(s.name) == H.lower(name) then
            return true
        end
    end
    return false
end

-- ── files: shared plan + one status file per account ────────
local FS = {}

function FS.ensure()
    if not (makefolder and isfolder) then
        return false
    end
    pcall(function()
        if not isfolder("AnimeDice") then makefolder("AnimeDice") end
        if not isfolder(K.DIR) then makefolder(K.DIR) end
    end)
    return true
end

function FS.readJson(path)
    if not (isfile and readfile) or not isfile(path) then
        return nil
    end
    local ok, data = pcall(function()
        return HttpService:JSONDecode(readfile(path))
    end)
    return ok and type(data) == "table" and data or nil
end

function FS.writeJson(path, data)
    if not writefile then
        return
    end
    FS.ensure()
    pcall(function()
        writefile(path, HttpService:JSONEncode(data))
    end)
end

function FS.savePlan()
    S.plan.rev = os.time() + math.random()
    S.planRev = S.plan.rev
    FS.writeJson(K.PLAN, S.plan)
end

function FS.loadPlan()
    local p = FS.readJson(K.PLAN)
    if p and p.rev ~= S.planRev then
        S.planRev = p.rev
        S.plan.receiver = p.receiver
        S.plan.senders = type(p.senders) == "table" and p.senders or {}
        S.plan.rules = type(p.rules) == "table" and p.rules or {}
        S.plan.all = p.all == true
        S.plan.running = p.running == true
        S.plan.wait = tonumber(p.wait) or 60
        S.plan.follow = p.follow == true
        S.plan.rev = p.rev
        return true
    end
    return false
end

function FS.writeStatus()
    local count, cap = H.storage()
    FS.writeJson(K.DIR .. "/" .. H.lower(LP.Name) .. ".json", {
        name = LP.Name,
        jobId = game.JobId,
        placeId = game.PlaceId,
        public = game.PrivateServerId == "",
        players = #Players:GetPlayers(),
        maxPlayers = Players.MaxPlayers,
        joinedAt = S.joinedAt,
        role = S.role,
        phase = S.phase,
        msg = S.msg,
        sent = S.sent,
        remaining = S.remaining,
        units = count,
        cap = cap,
        rolls = D.Rolls(),
        age = LP.AccountAge,
        t = os.time(),
    })
end

function FS.status(name)
    local st = FS.readJson(K.DIR .. "/" .. H.lower(name) .. ".json")
    if st and type(st.t) == "number" and os.time() - st.t <= K.FRESH then
        return st
    end
    return st and { stale = true, phase = st.phase, sent = st.sent } or nil
end

-- ════════════════════════════════════════════════════════════
-- TRADE ENGINE
-- ════════════════════════════════════════════════════════════
local T = { active = false, partner = nil, phase = nil, ownOffer = {}, otherOffer = {},
    ownReady = false, otherReady = false, ownAccepted = false, otherAccepted = false,
    ended = nil, incoming = nil, updSeq = 0, firedSeq = -1, firedAt = 0 }

if R.TradeEvent then
    R.TradeEvent.OnClientEvent:Connect(function(ev, data)
        data = data or {}
        if ev == "RequestReceived" then
            T.incoming = { player = data.player, at = os.clock() }
        elseif ev == "Started" then
            T.active = true
            T.partner = data.partner
            T.ended = nil
            T.phase = "Offer"
        elseif ev == "Updated" then
            T.updSeq = T.updSeq + 1
            T.phase = data.phase
            T.ownOffer = data.ownOffer or {}
            T.otherOffer = data.otherOffer or {}
            T.ownReady = data.ownReady
            T.otherReady = data.otherReady
            T.ownAccepted = data.ownAccepted
            T.otherAccepted = data.otherAccepted
        elseif ev == "Ended" then
            T.active = false
            T.ended = data.reason or "?"
            T.partner = nil
        end
    end)
end

-- AdvanceTrade toggles "ready" in the Offer phase: press again only after a newer Updated
local function advance()
    if T.updSeq ~= T.firedSeq or os.clock() - T.firedAt > 4 then
        T.firedSeq = T.updSeq
        T.firedAt = os.clock()
        fire(R.AdvanceTrade)
    end
end

local function waitFor(cond, timeout)
    local t0 = os.clock()
    while os.clock() - t0 < timeout do
        if cond() then
            return true
        end
        task.wait(0.2)
    end
    return cond()
end

-- one trade round with up to MAX_ENTRIES entries; returns ok, reason, itemsSent
local function tradeOnce(target, batch)
    local started = false
    for attempt = 1, 4 do
        if T.active then
            fire(R.CancelTrade)
            task.wait(1)
        end
        T.ended = nil
        S.msg = "requesting trade with " .. target.Name .. " (try " .. attempt .. ")"
        fire(R.RequestTrade, target)
        started = waitFor(function()
            return T.active
        end, 9)
        if started then
            break
        end
        task.wait(7)
    end
    if not started then
        return false, "receiver did not accept", 0
    end
    S.msg = "offering " .. #batch .. " entries"
    for _, it in ipairs(batch) do
        fire(R.ChangeOffer, it.key, it.amount)
        task.wait(0.22)
    end
    waitFor(function()
        for _, it in ipairs(batch) do
            if not T.ownOffer[it.key] then
                return false
            end
        end
        return true
    end, 10)
    local deadline = os.clock() + 60
    while T.active and os.clock() < deadline do
        if T.phase == "Offer" and not T.ownReady then
            advance()
        elseif T.phase == "Confirm" and not T.ownAccepted then
            advance()
        end
        S.msg = "trade phase " .. tostring(T.phase)
        task.wait(0.3)
    end
    if T.active then
        fire(R.CancelTrade) -- stuck: usually unit storage on one side
        task.wait(1)
    end
    waitFor(function()
        return T.ended ~= nil
    end, 15)
    local reason = T.ended or "timeout"
    if reason ~= "Completed" then
        return false, reason, 0
    end
    local n = 0
    for _, it in ipairs(batch) do
        n = n + it.amount
    end
    return true, reason, n
end

-- ── sender ──────────────────────────────────────────────────
local function senderTick()
    local plan = S.plan
    local recv = plan.receiver
    if not recv then
        S.phase, S.msg = "idle", "no receiver set"
        return
    end
    local items = H.toSend()
    S.remaining = #items
    if #items == 0 then
        if S.phase ~= "done" then
            log("nothing left to send - done (" .. S.sent .. " sent)", "Good")
        end
        S.phase, S.msg = "done", "everything sent"
        return
    end
    local target = H.findPlayer(recv.name)
    if not target then
        local st = FS.status(recv.name)
        if plan.follow and st and not st.stale and st.jobId and st.jobId ~= game.JobId then
            local open = (st.maxPlayers or 0) - (st.players or 0)
            if open >= 1 and os.time() - S.lastTp > 30 then
                S.phase, S.msg = "joining", "joining " .. recv.name .. "'s server"
                S.lastTp = os.time()
                if queue_on_teleport or queueonteleport then
                    pcall(queue_on_teleport or queueonteleport,
                        "repeat task.wait() until game:IsLoaded()\nloadstring(game:HttpGet(\"" .. K.URL .. "\"))()")
                end
                log("teleport to " .. recv.name .. "'s server")
                pcall(TeleportService.TeleportToPlaceInstance, TeleportService, game.PlaceId, st.jobId, LP)
                return
            end
            S.phase, S.msg = "waiting", recv.name .. "'s server " .. (open >= 1 and "- retrying join" or "is full")
            return
        end
        S.phase, S.msg = "waiting", "waiting for " .. recv.name .. " in this server"
        return
    end
    if LP.AccountAge < M.TradeConfig.MIN_ACCOUNT_AGE or D.Rolls() < M.TradeConfig.MIN_ROLLS then
        S.phase, S.msg = "error", "this account can't trade (age " .. LP.AccountAge .. "d, rolls " .. D.Rolls() .. ")"
        return
    end
    local waitLeft = (tonumber(plan.wait) or 60) - (os.time() - S.joinedAt)
    local rst = FS.status(recv.name)
    if rst and rst.joinedAt then
        waitLeft = math.max(waitLeft, (tonumber(plan.wait) or 60) - (os.time() - rst.joinedAt))
    end
    if waitLeft > 0 then
        S.phase, S.msg = "waiting", "same server · trading in " .. waitLeft .. "s"
        return
    end
    -- batch: max entries per trade, and no more units than the receiver has room for
    local room = math.huge
    if rst and not rst.stale and rst.cap and rst.units then
        room = math.max(0, rst.cap - rst.units)
    end
    local batch, units = {}, 0
    for _, it in ipairs(items) do
        if #batch >= K.MAX_ENTRIES then
            break
        end
        if not it.unit or units < room then
            table.insert(batch, it)
            if it.unit then
                units = units + 1
            end
        end
    end
    if #batch == 0 then
        S.phase, S.msg = "waiting", recv.name .. " has no free unit storage (" .. tostring(rst and rst.units) .. "/" .. tostring(rst and rst.cap) .. ")"
        return
    end
    S.phase = "trading"
    local ok, reason, n = tradeOnce(target, batch)
    if ok then
        S.sent = S.sent + n
        log("sent " .. #batch .. " entries (" .. n .. " items) to " .. recv.name, "Good")
        task.wait(2)
    else
        log("trade failed: " .. tostring(reason), "Bad")
        S.msg = "trade failed: " .. tostring(reason) .. " · retrying"
        task.wait(8)
    end
end

-- ── receiver ────────────────────────────────────────────────
local function receiverTick()
    if D.TradeRequestsEnabled and not D.TradeRequestsEnabled() then
        fire(R.SetTradeRequestsEnabled, true)
    end
    if T.incoming and os.clock() - T.incoming.at < 6 and not T.active then
        local p = T.incoming.player
        T.incoming = nil
        if p and H.isSender(p.Name) then
            fire(R.RespondToRequest, true)
            log("accepted trade from " .. p.Name)
        else
            fire(R.RespondToRequest, false)
        end
    end
    if T.active then
        if not T.partner or not H.isSender(T.partner.Name) then
            fire(R.CancelTrade)
            return
        end
        S.phase = "receiving"
        S.msg = "receiving from " .. T.partner.Name .. " · " .. tostring(T.phase)
        if T.phase == "Offer" and not T.ownReady and T.otherReady and #T.otherOffer > 0 then
            advance()
        elseif T.phase == "Confirm" and not T.ownAccepted then
            advance()
        end
        return
    end
    local here = 0
    for _, s in ipairs(S.plan.senders) do
        if H.findPlayer(s.name) then
            here = here + 1
        end
    end
    S.phase = "receiving"
    S.msg = "ready · " .. here .. "/" .. #S.plan.senders .. " senders in this server"
end

local function engineLoop()
    while alive() do
        local plan = S.plan
        if plan.receiver and H.lower(plan.receiver.name) == H.lower(LP.Name) then
            S.role = "receiver"
        elseif H.isSender(LP.Name) then
            S.role = "sender"
        else
            S.role = "editor"
        end
        local ok, err = pcall(function()
            if not plan.running then
                S.phase = "idle"
                S.msg = "stopped"
            elseif S.role == "sender" then
                senderTick()
            elseif S.role == "receiver" then
                receiverTick()
            else
                S.phase, S.msg = "idle", "this account is not in the plan"
            end
        end)
        if not ok then
            log("engine error: " .. tostring(err), "Bad")
            task.wait(2)
        end
        task.wait(S.role == "receiver" and 0.3 or 1)
    end
end

local function fileLoop()
    while alive() do
        if FS.loadPlan() then
            log("plan updated · receiver " .. tostring(S.plan.receiver and S.plan.receiver.name) ..
                " · " .. #S.plan.senders .. " senders · " .. (S.plan.running and "RUNNING" or "stopped"))
        end
        FS.writeStatus()
        for _, s in ipairs(S.plan.senders) do
            S.statuses[H.lower(s.name)] = FS.status(s.name)
        end
        if S.plan.receiver then
            S.statuses[H.lower(S.plan.receiver.name)] = FS.status(S.plan.receiver.name)
        end
        task.wait(2)
    end
end

-- the game's AFK.lua sends you to a new server after 18 min without input
local function antiAfk()
    pcall(function()
        local vu = game:GetService("VirtualUser")
        LP.Idled:Connect(function()
            vu:CaptureController()
            vu:ClickButton2(Vector2.new())
        end)
    end)
    while alive() do
        local done = false
        if getconnections then
            pcall(function()
                for _, c in ipairs(getconnections(UserInputService.InputBegan)) do
                    local f = c.Function
                    if f then
                        local okInfo, src = pcall(debug.info, f, "s")
                        if okInfo and type(src) == "string" and string.find(src, "AFK", 1, true) then
                            task.spawn(f)
                            done = true
                        end
                    end
                end
            end)
        end
        if not done then
            pcall(function()
                local vim = game:GetService("VirtualInputManager")
                vim:SendKeyEvent(true, Enum.KeyCode.F15, false, game)
                task.wait(0.05)
                vim:SendKeyEvent(false, Enum.KeyCode.F15, false, game)
            end)
        end
        S.afk = done and "game timer reset" or "key fallback"
        task.wait(240)
    end
end

-- ════════════════════════════════════════════════════════════
-- ICONS: the game's own EntryIcon (same tile as the backpack: 3D unit, item image, rarity
-- colours). Built on a separate worker thread because calling game modules that touch
-- Instances can strip the UI thread's capability on Potassium/Volt.
-- ════════════════════════════════════════════════════════════
local ICON = { queue = {}, done = {}, worker = nil }

function ICON.request(name, key, holder)
    table.insert(ICON.queue, { name = name, key = key, holder = holder })
end

function ICON.workerLoop()
    while alive() do
        local job = table.remove(ICON.queue, 1)
        if job then
            local ok, icon = pcall(function()
                return asGame(function()
                    local _, inst = M.EntryIcon.new({ name = job.name, key = job.key, tooltip = false })
                    return inst
                end)
            end)
            table.insert(ICON.done, { job = job, icon = ok and icon or nil, err = not ok and icon or nil })
        else
            task.wait(0.05)
        end
    end
end

-- ════════════════════════════════════════════════════════════
-- UI
-- ════════════════════════════════════════════════════════════
local UI = { gui = nil, conns = {}, el = {}, pages = {}, tabs = {}, tab = nil, tiles = {},
    rows = {}, filter = "All", search = "", refreshAt = 0, gridDirty = true, visible = true }

local TH = {
    Bg = Color3.fromRGB(13, 14, 19),
    Panel = Color3.fromRGB(20, 22, 29),
    Elevated = Color3.fromRGB(29, 31, 41),
    Hover = Color3.fromRGB(36, 39, 51),
    Stroke = Color3.fromRGB(44, 47, 60),
    Text = Color3.fromRGB(236, 238, 245),
    Sub = Color3.fromRGB(140, 145, 162),
    Dim = Color3.fromRGB(84, 88, 104),
    Accent = Color3.fromRGB(108, 138, 255),
    Good = Color3.fromRGB(74, 210, 128),
    Warn = Color3.fromRGB(240, 180, 64),
    Bad = Color3.fromRGB(232, 82, 92),
    Purple = Color3.fromRGB(190, 110, 255),
    Font = Enum.Font.GothamMedium,
    Bold = Enum.Font.GothamBold,
    Mono = Enum.Font.Code,
}
local PHASE = {
    idle = { title = "IDLE", color = TH.Dim },
    waiting = { title = "WAITING", color = TH.Warn },
    joining = { title = "JOINING", color = Color3.fromRGB(64, 200, 230) },
    trading = { title = "TRADING", color = TH.Purple },
    receiving = { title = "RECEIVING", color = TH.Accent },
    done = { title = "DONE", color = TH.Good },
    error = { title = "ERROR", color = TH.Bad },
}
local MOTION = {
    Fast = TweenInfo.new(0.12, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
    Base = TweenInfo.new(0.25, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
    Slow = TweenInfo.new(0.45, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
    Spring = TweenInfo.new(0.45, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
}

function UI.new(class, props, children)
    local inst = Instance.new(class)
    local parent = nil
    for k, v in pairs(props or {}) do
        if k == "Parent" then
            parent = v
        else
            inst[k] = v
        end
    end
    for _, c in ipairs(children or {}) do
        c.Parent = inst
    end
    if parent then
        inst.Parent = parent
    end
    return inst
end

function UI.tween(inst, info, goal)
    local t = TweenService:Create(inst, info, goal)
    t:Play()
    return t
end

function UI.corner(r)
    return UI.new("UICorner", { CornerRadius = r and UDim.new(0, r) or UDim.new(1, 0) })
end

function UI.stroke(color, t)
    return UI.new("UIStroke", { Color = color or TH.Stroke, Transparency = t or 0,
        ApplyStrokeMode = Enum.ApplyStrokeMode.Border })
end

function UI.pad(px)
    return UI.new("UIPadding", { PaddingLeft = UDim.new(0, px), PaddingRight = UDim.new(0, px),
        PaddingTop = UDim.new(0, px), PaddingBottom = UDim.new(0, px) })
end

function UI.label(text, size, color, font, props)
    local l = UI.new("TextLabel", {
        BackgroundTransparency = 1,
        Text = text,
        TextSize = size,
        TextColor3 = color,
        Font = font or TH.Font,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd,
    })
    for k, v in pairs(props or {}) do
        l[k] = v
    end
    return l
end

function UI.track(c)
    table.insert(UI.conns, c)
    return c
end

-- press feedback: shrink on down, spring back on up
function UI.press(b)
    local sc = b:FindFirstChildOfClass("UIScale") or UI.new("UIScale", { Parent = b })
    UI.track(b.MouseButton1Down:Connect(function()
        UI.tween(sc, MOTION.Fast, { Scale = 0.95 })
    end))
    UI.track(b.MouseButton1Up:Connect(function()
        UI.tween(sc, MOTION.Spring, { Scale = 1 })
    end))
    UI.track(b.MouseLeave:Connect(function()
        UI.tween(sc, MOTION.Spring, { Scale = 1 })
    end))
end

function UI.button(parent, text, color, props, onClick)
    local b = UI.new("TextButton", {
        AutoButtonColor = false,
        Text = text,
        TextSize = 12,
        Font = TH.Bold,
        TextColor3 = TH.Text,
        BackgroundColor3 = color or TH.Elevated,
        Parent = parent,
    }, { UI.corner(8) })
    for k, v in pairs(props or {}) do
        b[k] = v
    end
    UI.press(b)
    local base = b.BackgroundColor3
    UI.track(b.MouseEnter:Connect(function()
        UI.tween(b, MOTION.Fast, { BackgroundColor3 = base:Lerp(Color3.new(1, 1, 1), 0.08) })
    end))
    UI.track(b.MouseLeave:Connect(function()
        UI.tween(b, MOTION.Fast, { BackgroundColor3 = base })
    end))
    UI.track(b.Activated:Connect(function()
        task.spawn(function()
            local ok, err = pcall(onClick, b)
            if not ok then
                log("button error: " .. tostring(err), "Bad")
                UI.toast("error: " .. tostring(err), "Bad")
            end
        end)
    end))
    return b
end

function UI.input(parent, placeholder, props)
    local box = UI.new("TextBox", {
        BackgroundColor3 = TH.Panel,
        PlaceholderText = placeholder,
        PlaceholderColor3 = TH.Dim,
        Text = "",
        TextSize = 13,
        Font = TH.Font,
        TextColor3 = TH.Text,
        TextXAlignment = Enum.TextXAlignment.Left,
        ClearTextOnFocus = false,
        Parent = parent,
    }, { UI.corner(8), UI.new("UIPadding", { PaddingLeft = UDim.new(0, 12), PaddingRight = UDim.new(0, 12) }) })
    local st = UI.stroke(TH.Stroke)
    st.Parent = box
    UI.track(box.Focused:Connect(function()
        UI.tween(st, MOTION.Fast, { Color = TH.Accent })
    end))
    UI.track(box.FocusLost:Connect(function()
        UI.tween(st, MOTION.Fast, { Color = TH.Stroke })
    end))
    for k, v in pairs(props or {}) do
        box[k] = v
    end
    return box
end

function UI.section(parent, text, order)
    return UI.label(string.upper(text), 10, TH.Dim, TH.Bold, {
        Size = UDim2.new(1, 0, 0, 14), LayoutOrder = order, Parent = parent })
end

function UI.toast(text, kind)
    if not UI.gui then
        return
    end
    local color = kind == "Bad" and TH.Bad or (kind == "Good" and TH.Good or TH.Accent)
    local t = UI.new("Frame", {
        AnchorPoint = Vector2.new(0.5, 1),
        Position = UDim2.new(0.5, 0, 0, -4),
        Size = UDim2.fromOffset(0, 30),
        AutomaticSize = Enum.AutomaticSize.X,
        BackgroundColor3 = TH.Panel,
        BackgroundTransparency = 1,
        ZIndex = 50,
        Parent = UI.el.win,
    }, { UI.corner(), UI.new("UIPadding", { PaddingLeft = UDim.new(0, 14), PaddingRight = UDim.new(0, 14) }) })
    local s = UI.stroke(color, 1)
    s.Parent = t
    local l = UI.label(text, 12, TH.Text, TH.Bold, { Size = UDim2.new(0, 0, 1, 0),
        AutomaticSize = Enum.AutomaticSize.X, TextTransparency = 1, ZIndex = 51, Parent = t })
    UI.tween(t, MOTION.Spring, { Position = UDim2.new(0.5, 0, 0, -10), BackgroundTransparency = 0 })
    UI.tween(s, MOTION.Base, { Transparency = 0.2 })
    UI.tween(l, MOTION.Base, { TextTransparency = 0 })
    task.delay(2.8, function()
        if t.Parent then
            UI.tween(t, MOTION.Base, { BackgroundTransparency = 1 })
            UI.tween(s, MOTION.Base, { Transparency = 1 })
            UI.tween(l, MOTION.Base, { TextTransparency = 1 })
            task.wait(0.3)
            t:Destroy()
        end
    end)
end

-- round avatar with a glowing ring; returns setter(userId, ringColor)
function UI.avatar(parent, size, props)
    local holder = UI.new("Frame", { Size = UDim2.fromOffset(size, size), BackgroundColor3 = TH.Elevated,
        Parent = parent }, { UI.corner() })
    for k, v in pairs(props or {}) do
        holder[k] = v
    end
    local img = UI.new("ImageLabel", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1),
        ImageTransparency = 1, Parent = holder }, { UI.corner() })
    local ring = UI.new("UIStroke", { Color = TH.Stroke, Thickness = 2, Parent = holder })
    local api = { holder = holder, ring = ring }
    function api.set(userId, color)
        ring.Color = color or TH.Stroke
        if not userId then
            img.ImageTransparency = 1
            return
        end
        task.spawn(function()
            local ok, url = pcall(Players.GetUserThumbnailAsync, Players, userId,
                Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size150x150)
            if ok and url and holder.Parent then
                img.Image = url
                img.ImageTransparency = 1
                UI.tween(img, MOTION.Slow, { ImageTransparency = 0 })
            end
        end)
    end
    return api
end

function UI.chip(parent, text, color, props)
    local c = UI.new("TextLabel", {
        BackgroundColor3 = color or TH.Elevated,
        BackgroundTransparency = 0.82,
        Size = UDim2.fromOffset(0, 20),
        AutomaticSize = Enum.AutomaticSize.X,
        Text = text,
        TextSize = 11,
        Font = TH.Bold,
        TextColor3 = color or TH.Sub,
        Parent = parent,
    }, { UI.corner(), UI.new("UIPadding", { PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8) }) })
    for k, v in pairs(props or {}) do
        c[k] = v
    end
    return c
end

function UI.toggle(parent, text, getOn, onChange, order)
    local row = UI.new("TextButton", { AutoButtonColor = false, Text = "", BackgroundColor3 = TH.Panel,
        Size = UDim2.new(1, 0, 0, 38), LayoutOrder = order, Parent = parent }, { UI.corner(8), UI.stroke() })
    UI.label(text, 13, TH.Text, TH.Font, { Position = UDim2.fromOffset(12, 0), Size = UDim2.new(1, -70, 1, 0),
        Parent = row })
    local track = UI.new("Frame", { AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -12, 0.5, 0),
        Size = UDim2.fromOffset(38, 20), BackgroundColor3 = TH.Elevated, Parent = row }, { UI.corner() })
    local knob = UI.new("Frame", { AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 3, 0.5, 0),
        Size = UDim2.fromOffset(14, 14), BackgroundColor3 = TH.Sub, Parent = track }, { UI.corner() })
    local function paint()
        local on = getOn()
        UI.tween(track, MOTION.Base, { BackgroundColor3 = on and TH.Accent or TH.Elevated })
        UI.tween(knob, MOTION.Spring, { Position = on and UDim2.new(1, -17, 0.5, 0) or UDim2.new(0, 3, 0.5, 0),
            BackgroundColor3 = on and TH.Text or TH.Sub })
    end
    UI.track(row.Activated:Connect(function()
        onChange(not getOn())
        paint()
    end))
    paint()
    return { row = row, paint = paint }
end

function UI.scroller(parent, props)
    local sf = UI.new("ScrollingFrame", {
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        ScrollBarThickness = 3,
        ScrollBarImageColor3 = TH.Stroke,
        CanvasSize = UDim2.new(),
        AutomaticCanvasSize = Enum.AutomaticSize.Y,
        Parent = parent,
    })
    for k, v in pairs(props or {}) do
        sf[k] = v
    end
    return sf
end

function UI.page(name, order)
    local page = UI.new("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Visible = false,
        Parent = UI.el.pages }, { UI.pad(16) })
    local btn = UI.new("TextButton", { AutoButtonColor = false, Text = "", BackgroundColor3 = TH.Elevated,
        BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 36), LayoutOrder = order,
        Parent = UI.el.sidebar }, { UI.corner(8) })
    local l = UI.label(name, 13, TH.Sub, TH.Bold, { Position = UDim2.fromOffset(14, 0),
        Size = UDim2.new(1, -20, 1, 0), Parent = btn })
    local tab = { name = name, page = page, btn = btn, label = l, order = order }
    UI.tabs[name] = tab
    UI.pages[name] = page
    UI.track(btn.Activated:Connect(function()
        UI.select(name)
    end))
    UI.track(btn.MouseEnter:Connect(function()
        if UI.tab ~= tab then
            UI.tween(btn, MOTION.Fast, { BackgroundTransparency = 0.4 })
        end
    end))
    UI.track(btn.MouseLeave:Connect(function()
        if UI.tab ~= tab then
            UI.tween(btn, MOTION.Fast, { BackgroundTransparency = 1 })
        end
    end))
    return page
end

function UI.select(name)
    local tab = UI.tabs[name]
    if not tab or UI.tab == tab then
        return
    end
    if UI.tab then
        UI.tab.page.Visible = false
        UI.tween(UI.tab.btn, MOTION.Fast, { BackgroundTransparency = 1 })
        UI.tween(UI.tab.label, MOTION.Fast, { TextColor3 = TH.Sub })
    end
    UI.tab = tab
    tab.page.Visible = true
    tab.page.Position = UDim2.fromOffset(0, 10)
    UI.tween(tab.page, MOTION.Slow, { Position = UDim2.fromOffset(0, 0) })
    UI.tween(tab.btn, MOTION.Base, { BackgroundTransparency = 0 })
    UI.tween(tab.label, MOTION.Base, { TextColor3 = TH.Text })
    -- sliding indicator
    -- sidebar starts at y=47, 10px top padding, 36px buttons + 4px gap
    UI.tween(UI.el.indicator, MOTION.Spring, {
        Position = UDim2.fromOffset(4, 47 + 10 + (tab.order - 1) * 40 + 9) })
    if name == "Items" then
        UI.gridDirty = true
    end
end

-- ── window ──────────────────────────────────────────────────
function UI.fitScale()
    local vp = workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize or Vector2.new(1920, 1080)
    local byH = (vp.Y * 0.82) / 580
    local byW = (vp.X * 0.9) / 880
    return math.clamp(math.min(byH, byW), 0.55, 1.15)
end

function UI.build()
    local parent
    local okH, h = pcall(function()
        return gethui and gethui()
    end)
    parent = (okH and h) or game:GetService("CoreGui")
    local old = parent:FindFirstChild("AnimeDiceTradeHub")
    if old then
        old:Destroy()
    end
    local gui = UI.new("ScreenGui", { Name = "AnimeDiceTradeHub", ResetOnSpawn = false, IgnoreGuiInset = true,
        ZIndexBehavior = Enum.ZIndexBehavior.Sibling, DisplayOrder = 999 })
    gui.Parent = parent
    UI.gui = gui
    local el = UI.el

    el.win = UI.new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5),
        Size = UDim2.fromOffset(880, 580), BackgroundColor3 = TH.Bg, Parent = gui },
        { UI.corner(14), UI.new("UIScale", { Scale = 0.9 }) })
    el.scale = el.win:FindFirstChildOfClass("UIScale")
    el.border = UI.new("UIStroke", { Color = Color3.new(1, 1, 1), Thickness = 1.5, Parent = el.win })
    el.sweep = UI.new("UIGradient", { Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0, TH.Stroke), ColorSequenceKeypoint.new(0.5, TH.Accent),
        ColorSequenceKeypoint.new(1, TH.Stroke) }), Parent = el.border })

    -- header
    local header = UI.new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 46), Parent = el.win })
    UI.label("ANIME DICE", 13, TH.Text, TH.Bold, { Position = UDim2.fromOffset(18, 0),
        Size = UDim2.fromOffset(90, 46), Parent = header })
    UI.label("· Linggung", 13, TH.Dim, TH.Bold, { Position = UDim2.fromOffset(104, 0),
        Size = UDim2.fromOffset(90, 46), Parent = header })
    UI.chip(header, "TRADE HUB", TH.Purple, { AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 190, 0.5, 0) })
    el.roleChip = UI.chip(header, "EDITOR", TH.Sub, { AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.new(1, -76, 0.5, 0) })
    local function topButton(text, x, hover, fn)
        local b = UI.new("TextButton", { AutoButtonColor = false, AnchorPoint = Vector2.new(1, 0.5),
            Position = UDim2.new(1, x, 0.5, 0), Size = UDim2.fromOffset(26, 26), BackgroundColor3 = TH.Elevated,
            BackgroundTransparency = 1, Text = text, TextSize = 16, Font = TH.Bold, TextColor3 = TH.Dim,
            Parent = header }, { UI.corner(7) })
        UI.track(b.MouseEnter:Connect(function()
            UI.tween(b, MOTION.Fast, { BackgroundTransparency = 0, TextColor3 = hover })
        end))
        UI.track(b.MouseLeave:Connect(function()
            UI.tween(b, MOTION.Fast, { BackgroundTransparency = 1, TextColor3 = TH.Dim })
        end))
        UI.track(b.Activated:Connect(fn))
    end
    topButton("×", -12, TH.Bad, function()
        if LP:GetAttribute("AnimeDiceGiftRun") == TOKEN then
            LP:SetAttribute("AnimeDiceGiftRun", nil)
        end
        UI.destroy()
    end)
    topButton("–", -42, TH.Text, function()
        UI.visible = false
        UI.gui.Enabled = false
        log("hidden · RightCtrl to show")
    end)
    do
        local dragging, startMouse, startPos = false, nil, nil
        UI.track(header.InputBegan:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
                dragging = true
                startMouse = input.Position
                startPos = el.win.Position
            end
        end))
        UI.track(UserInputService.InputEnded:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
                dragging = false
            end
        end))
        UI.track(UserInputService.InputChanged:Connect(function(input)
            if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
                or input.UserInputType == Enum.UserInputType.Touch) then
                local d = input.Position - startMouse
                UI.tween(el.win, MOTION.Fast, { Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X,
                    startPos.Y.Scale, startPos.Y.Offset + d.Y) })
            end
        end))
    end
    UI.new("Frame", { BackgroundColor3 = TH.Stroke, BorderSizePixel = 0, Position = UDim2.fromOffset(0, 46),
        Size = UDim2.new(1, 0, 0, 1), Parent = el.win })

    -- sidebar
    -- sidebar keeps the window's rounded bottom-left corner: rounded frame + square fillers
    local sideBg = UI.new("Frame", { BackgroundColor3 = TH.Panel, BorderSizePixel = 0,
        Position = UDim2.fromOffset(0, 47), Size = UDim2.new(0, 150, 1, -47), Parent = el.win }, { UI.corner(14) })
    UI.new("Frame", { BackgroundColor3 = TH.Panel, BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, 16), Parent = sideBg })
    UI.new("Frame", { BackgroundColor3 = TH.Panel, BorderSizePixel = 0, AnchorPoint = Vector2.new(1, 0),
        Position = UDim2.fromScale(1, 0), Size = UDim2.new(0, 16, 1, 0), Parent = sideBg })
    el.sidebar = UI.new("Frame", { BackgroundTransparency = 1, BorderSizePixel = 0,
        Position = UDim2.fromOffset(0, 47), Size = UDim2.new(0, 150, 1, -47), Parent = el.win },
        { UI.new("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }),
          UI.new("UIPadding", { PaddingTop = UDim.new(0, 10), PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10) }) })
    el.indicator = UI.new("Frame", { BackgroundColor3 = TH.Accent, BorderSizePixel = 0, Size = UDim2.fromOffset(3, 18),
        Position = UDim2.fromOffset(4, 66), ZIndex = 3, Parent = el.win }, { UI.corner(2) })
    el.pages = UI.new("Frame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(150, 47),
        Size = UDim2.new(1, -150, 1, -47), ClipsDescendants = true, Parent = el.win })

    -- mini status at the bottom of the sidebar
    el.sideStatus = UI.new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 60), LayoutOrder = 99,
        Parent = el.sidebar })
    el.sideDot = UI.new("Frame", { Position = UDim2.fromOffset(4, 24), Size = UDim2.fromOffset(10, 10),
        BackgroundColor3 = TH.Dim, Parent = el.sideStatus }, { UI.corner() })
    el.sidePhase = UI.label("IDLE", 12, TH.Text, TH.Bold, { Position = UDim2.fromOffset(20, 16),
        Size = UDim2.new(1, -20, 0, 16), Parent = el.sideStatus })
    el.sideName = UI.label(LP.Name, 10, TH.Dim, TH.Font, { Position = UDim2.fromOffset(20, 32),
        Size = UDim2.new(1, -20, 0, 14), Parent = el.sideStatus })

    UI.buildReceiver(UI.page("Receiver", 1))
    UI.buildSenders(UI.page("Senders", 2))
    UI.buildItems(UI.page("Items", 3))
    UI.buildRun(UI.page("Run", 4))
    -- spacer pushes the status block down
    UI.new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 290), LayoutOrder = 50, Parent = el.sidebar })

    el.win.BackgroundTransparency = 1
    UI.tween(el.win, MOTION.Slow, { BackgroundTransparency = 0 })
    UI.tween(el.scale, MOTION.Spring, { Scale = UI.fitScale() })
    UI.track(workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
        UI.tween(el.scale, MOTION.Base, { Scale = UI.fitScale() })
    end))
    task.defer(function()
        UI.select(S.plan.receiver and "Run" or "Receiver")
    end)

    UI.track(UserInputService.InputBegan:Connect(function(input, gp)
        if not gp and input.KeyCode == Enum.KeyCode.RightControl then
            UI.visible = not UI.visible
            UI.gui.Enabled = UI.visible
        end
    end))
    UI.track(RunService.Heartbeat:Connect(UI.frame))
end

-- ── Receiver page ───────────────────────────────────────────
function UI.lookup(name, cb)
    task.spawn(function()
        local ok, id = pcall(Players.GetUserIdFromNameAsync, Players, name)
        if not ok or not id then
            cb(nil)
            return
        end
        local display, realName = name, name
        local okInfo, info = pcall(function()
            return game:GetService("UserService"):GetUserInfosByUserIdsAsync({ id })
        end)
        if okInfo and info and info[1] then
            display = info[1].DisplayName or display
            realName = info[1].Username or realName
        end
        cb({ name = realName, userId = id, display = display })
    end)
end

function UI.buildReceiver(page)
    local el = UI.el
    UI.new("UIListLayout", { Padding = UDim.new(0, 10), SortOrder = Enum.SortOrder.LayoutOrder, Parent = page })
    UI.section(page, "Receiver account", 1)
    local row = UI.new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 38), LayoutOrder = 2, Parent = page })
    el.recvBox = UI.input(row, "receiver username…", { Size = UDim2.new(1, -110, 1, 0) })
    local checkBtn = UI.button(row, "Check", TH.Accent, { AnchorPoint = Vector2.new(1, 0), Position = UDim2.fromScale(1, 0),
        Size = UDim2.new(0, 100, 1, 0) }, function()
        UI.checkReceiver(el.recvBox.Text)
    end)
    UI.track(el.recvBox.FocusLost:Connect(function(enter)
        if enter then
            UI.checkReceiver(el.recvBox.Text)
        end
    end))
    el.recvCheckBtn = checkBtn

    -- profile card
    local card = UI.new("Frame", { BackgroundColor3 = TH.Panel, Size = UDim2.new(1, 0, 0, 150), LayoutOrder = 3,
        Parent = page }, { UI.corner(12), UI.stroke() })
    el.recvCard = card
    el.recvAvatar = UI.avatar(card, 104, { Position = UDim2.fromOffset(18, 23) })
    el.recvDisplay = UI.label("No receiver yet", 20, TH.Text, TH.Bold, { Position = UDim2.fromOffset(140, 22),
        Size = UDim2.new(1, -156, 0, 26), Parent = card })
    el.recvUser = UI.label("type a username and press Check", 12, TH.Sub, TH.Font, { Position = UDim2.fromOffset(140, 48),
        Size = UDim2.new(1, -156, 0, 16), Parent = card })
    el.recvChips = UI.new("Frame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(140, 74),
        Size = UDim2.new(1, -156, 0, 46), Parent = card }, {
        UI.new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Wraps = true,
            Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }) })
    el.recvVerdict = UI.label("", 12, TH.Sub, TH.Bold, { Position = UDim2.fromOffset(140, 122),
        Size = UDim2.new(1, -156, 0, 16), Parent = card })

    el.recvSet = UI.button(page, "Set as receiver", TH.Good, { Size = UDim2.new(1, 0, 0, 40), LayoutOrder = 4,
        TextColor3 = TH.Bg, TextSize = 14, Visible = false }, function()
        if not UI.pendingRecv then
            return
        end
        S.plan.receiver = UI.pendingRecv
        FS.savePlan()
        UI.toast("Receiver set: " .. UI.pendingRecv.name, "Good")
        log("receiver set to " .. UI.pendingRecv.name, "Good")
        UI.renderReceiver(S.plan.receiver, true)
    end)
    UI.label("The plan is saved to workspace/AnimeDice/gift/plan.json - every screen on this PC follows it.",
        11, TH.Dim, TH.Font, { Size = UDim2.new(1, 0, 0, 30), TextWrapped = true, LayoutOrder = 5, Parent = page })
end

function UI.checkReceiver(text)
    local name = string.gsub(text or "", "%s", "")
    if name == "" then
        UI.toast("type a username first", "Bad")
        return
    end
    UI.el.recvDisplay.Text = "Checking…"
    UI.el.recvUser.Text = "@" .. name
    UI.lookup(name, function(info)
        if not info then
            UI.pendingRecv = nil
            UI.el.recvDisplay.Text = "User not found"
            UI.el.recvUser.Text = "@" .. name
            UI.el.recvAvatar.set(nil, TH.Bad)
            UI.el.recvVerdict.Text = "✕ no Roblox account with that username"
            UI.el.recvVerdict.TextColor3 = TH.Bad
            UI.el.recvSet.Visible = false
            return
        end
        UI.pendingRecv = info
        UI.renderReceiver(info, false)
    end)
end

-- fills the card with what we can verify: Roblox account, in this server, age/rolls/storage
function UI.renderReceiver(info, saved)
    local el = UI.el
    if not info then
        return
    end
    el.recvDisplay.Text = info.display or info.name
    el.recvUser.Text = "@" .. info.name .. "  ·  ID " .. tostring(info.userId)
    for _, c in ipairs(el.recvChips:GetChildren()) do
        if c:IsA("TextLabel") then
            c:Destroy()
        end
    end
    local plr = H.findPlayer(info.name)
    local st = FS.status(info.name)
    local okAll = true
    if plr then
        UI.chip(el.recvChips, "● in this server", TH.Good)
        local age = plr.AccountAge
        local ageOk = age >= M.TradeConfig.MIN_ACCOUNT_AGE
        okAll = okAll and ageOk
        UI.chip(el.recvChips, "age " .. age .. "d", ageOk and TH.Good or TH.Bad)
    else
        UI.chip(el.recvChips, "○ not in this server", TH.Warn)
    end
    if st and not st.stale then
        local rollsOk = (st.rolls or 0) >= M.TradeConfig.MIN_ROLLS
        okAll = okAll and rollsOk
        UI.chip(el.recvChips, "rolls " .. H.fmt(st.rolls or 0), rollsOk and TH.Good or TH.Bad)
        UI.chip(el.recvChips, "units " .. tostring(st.units) .. "/" .. tostring(st.cap), TH.Accent)
        UI.chip(el.recvChips, "script online", TH.Good)
    else
        UI.chip(el.recvChips, "script not running", TH.Dim)
    end
    local color = okAll and (plr and TH.Good or TH.Warn) or TH.Bad
    el.recvAvatar.set(info.userId, color)
    if saved then
        el.recvVerdict.Text = "✓ current receiver"
        el.recvVerdict.TextColor3 = TH.Good
        el.recvSet.Visible = false
    else
        el.recvVerdict.Text = okAll and "✓ looks right - press Set as receiver" or "! check the red items before setting"
        el.recvVerdict.TextColor3 = okAll and TH.Good or TH.Warn
        el.recvSet.Visible = true
        el.recvSet.Size = UDim2.new(1, 0, 0, 0)
        UI.tween(el.recvSet, MOTION.Spring, { Size = UDim2.new(1, 0, 0, 40) })
    end
    -- pop the card
    local sc = el.recvCard:FindFirstChildOfClass("UIScale") or UI.new("UIScale", { Parent = el.recvCard })
    sc.Scale = 0.97
    UI.tween(sc, MOTION.Spring, { Scale = 1 })
end

-- ── Senders page ────────────────────────────────────────────
function UI.buildSenders(page)
    local el = UI.el
    UI.new("UIListLayout", { Padding = UDim.new(0, 10), SortOrder = Enum.SortOrder.LayoutOrder, Parent = page })
    UI.section(page, "Sender accounts", 1)
    -- paste box: one name, or a whole list (new lines, spaces or commas between)
    local row = UI.new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 82), LayoutOrder = 2, Parent = page })
    el.sendBox = UI.input(row, "Paste usernames - one per line, or separated by space / comma (50 at once is fine)",
        { Size = UDim2.new(1, -150, 1, 0), MultiLine = true, TextWrapped = true, ClipsDescendants = true,
          TextYAlignment = Enum.TextYAlignment.Top, TextSize = 12 })
    el.sendBox:FindFirstChildOfClass("UIPadding").PaddingTop = UDim.new(0, 10)
    el.sendBox:FindFirstChildOfClass("UIPadding").PaddingBottom = UDim.new(0, 10)
    el.addBtn = UI.button(row, "Add", TH.Accent, { AnchorPoint = Vector2.new(1, 0), Position = UDim2.fromScale(1, 0),
        Size = UDim2.new(0, 140, 0, 38) }, function()
        local text = el.sendBox.Text
        el.sendBox.Text = ""
        UI.addSenders(text)
    end)
    UI.button(row, "Add me", TH.Elevated, { AnchorPoint = Vector2.new(1, 1), Position = UDim2.fromScale(1, 1),
        Size = UDim2.new(0, 140, 0, 38) }, function()
        UI.addSenders(LP.Name)
    end)
    -- progress bar for bulk adds
    el.addTrack = UI.new("Frame", { BackgroundColor3 = TH.Elevated, Size = UDim2.new(1, 0, 0, 4), LayoutOrder = 3,
        Visible = false, Parent = page }, { UI.corner() })
    el.addFill = UI.new("Frame", { BackgroundColor3 = TH.Accent, Size = UDim2.fromScale(0, 1), Parent = el.addTrack }, { UI.corner() })
    local countRow = UI.new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 22), LayoutOrder = 4, Parent = page })
    el.sendCount = UI.label("0 senders", 11, TH.Dim, TH.Bold, { Size = UDim2.new(1, -120, 1, 0), Parent = countRow })
    UI.button(countRow, "Clear list", TH.Panel, { AnchorPoint = Vector2.new(1, 0), Position = UDim2.fromScale(1, 0),
        Size = UDim2.fromOffset(110, 22), TextColor3 = TH.Bad, TextSize = 11 }, function()
        if #S.plan.senders == 0 then
            return
        end
        if UI.confirmClear and os.clock() - UI.confirmClear < 3 then
            UI.confirmClear = nil
            S.plan.senders = {}
            FS.savePlan()
            UI.renderSenders()
            UI.toast("Sender list cleared", "Bad")
        else
            UI.confirmClear = os.clock()
            UI.toast("Press Clear list again to remove all " .. #S.plan.senders, "Bad")
        end
    end)
    el.sendList = UI.scroller(page, { Size = UDim2.new(1, 0, 1, -168), LayoutOrder = 5 })
    UI.new("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder, Parent = el.sendList })
end

-- checks every name against Roblox one after another (with a progress bar) and saves once
function UI.addSenders(text)
    if UI.adding then
        UI.toast("still adding the previous list…", "Bad")
        return
    end
    local names, seen = {}, {}
    for name in string.gmatch(text or "", "[%w_]+") do
        local key = H.lower(name)
        if not seen[key] then
            seen[key] = true
            table.insert(names, name)
        end
    end
    if #names == 0 then
        UI.toast("type or paste usernames first", "Bad")
        return
    end
    UI.adding = true
    local el = UI.el
    task.spawn(function()
        local added, skipped, missing = {}, 0, {}
        el.addTrack.Visible = true
        el.addFill.Size = UDim2.fromScale(0, 1)
        for i, name in ipairs(names) do
            el.sendCount.Text = "checking " .. i .. " / " .. #names .. " · @" .. name
            UI.tween(el.addFill, MOTION.Base, { Size = UDim2.fromScale(i / #names, 1) })
            local isRecv = S.plan.receiver and H.lower(S.plan.receiver.name) == H.lower(name)
            if H.isSender(name) or isRecv then
                skipped = skipped + 1
            else
                local id = nil
                for attempt = 1, 3 do
                    local ok, res = pcall(Players.GetUserIdFromNameAsync, Players, name)
                    if ok and res then
                        id = res
                        break
                    end
                    -- a real "not found" fails the same way, so only retry briefly (rate limits)
                    task.wait(0.4 * attempt)
                end
                if id then
                    table.insert(added, { name = name, userId = id, display = name })
                    table.insert(S.plan.senders, added[#added])
                    if #added % 10 == 0 then
                        UI.renderSenders()
                    end
                else
                    table.insert(missing, name)
                end
            end
            task.wait(0.05)
        end
        -- exact usernames + display names in one request
        if #added > 0 then
            local ids = {}
            for _, a in ipairs(added) do
                table.insert(ids, a.userId)
            end
            local ok, infos = pcall(function()
                return game:GetService("UserService"):GetUserInfosByUserIdsAsync(ids)
            end)
            if ok and type(infos) == "table" then
                local byId = {}
                for _, inf in ipairs(infos) do
                    byId[inf.Id] = inf
                end
                for _, a in ipairs(added) do
                    local inf = byId[a.userId]
                    if inf then
                        a.name = inf.Username or a.name
                        a.display = inf.DisplayName or a.name
                    end
                end
            end
        end
        FS.savePlan()
        UI.renderSenders()
        UI.tween(el.addFill, MOTION.Base, { Size = UDim2.fromScale(1, 1) })
        task.wait(0.4)
        el.addTrack.Visible = false
        UI.adding = false
        local msg = "added " .. #added
        if skipped > 0 then
            msg = msg .. " · " .. skipped .. " already in"
        end
        if #missing > 0 then
            msg = msg .. " · " .. #missing .. " not found"
            log("not found: " .. table.concat(missing, ", "), "Bad")
            -- keep the bad names in the box so they can be fixed
            el.sendBox.Text = table.concat(missing, "\n")
        end
        UI.toast(msg, #missing > 0 and "Bad" or "Good")
        log("senders: " .. msg)
    end)
end

function UI.renderSenders()
    local el = UI.el
    local keep = {}
    for i, s in ipairs(S.plan.senders) do
        local key = H.lower(s.name)
        keep[key] = true
        local r = UI.rows[key]
        if not r then
            local f = UI.new("Frame", { BackgroundColor3 = TH.Panel, Size = UDim2.new(1, -6, 0, 54),
                BackgroundTransparency = 1, Parent = el.sendList }, { UI.corner(10) })
            local st = UI.stroke(TH.Stroke, 1)
            st.Parent = f
            local av = UI.avatar(f, 38, { Position = UDim2.fromOffset(10, 8) })
            av.set(s.userId, TH.Stroke)
            local nm = UI.label(s.display or s.name, 13, TH.Text, TH.Bold, { Position = UDim2.fromOffset(58, 9),
                Size = UDim2.new(1, -250, 0, 18), Parent = f })
            UI.label("@" .. s.name, 11, TH.Dim, TH.Font, { Position = UDim2.fromOffset(58, 28),
                Size = UDim2.new(1, -250, 0, 14), Parent = f })
            local pill = UI.chip(f, "OFFLINE", TH.Dim, { AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -48, 0.5, -7) })
            local info = UI.label("", 10, TH.Dim, TH.Font, { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -48, 0.5, 6),
                Size = UDim2.fromOffset(170, 14), TextXAlignment = Enum.TextXAlignment.Right, Parent = f })
            local rm = UI.new("TextButton", { AutoButtonColor = false, AnchorPoint = Vector2.new(1, 0.5),
                Position = UDim2.new(1, -10, 0.5, 0), Size = UDim2.fromOffset(28, 28), BackgroundColor3 = TH.Elevated,
                Text = "×", TextSize = 16, Font = TH.Bold, TextColor3 = TH.Dim, Parent = f }, { UI.corner(7) })
            UI.press(rm)
            UI.track(rm.Activated:Connect(function()
                for j, x in ipairs(S.plan.senders) do
                    if H.lower(x.name) == key then
                        table.remove(S.plan.senders, j)
                        break
                    end
                end
                FS.savePlan()
                UI.renderSenders()
            end))
            r = { frame = f, stroke = st, avatar = av, pill = pill, info = info, name = nm }
            UI.rows[key] = r
            -- slide in
            f.Position = UDim2.fromOffset(30, 0)
            UI.tween(f, MOTION.Slow, { BackgroundTransparency = 0 })
            UI.tween(st, MOTION.Slow, { Transparency = 0 })
        end
        r.frame.LayoutOrder = i
    end
    for key, r in pairs(UI.rows) do
        if not keep[key] then
            UI.rows[key] = nil
            UI.tween(r.frame, MOTION.Base, { BackgroundTransparency = 1, Size = UDim2.new(1, -6, 0, 0) })
            task.delay(0.26, function()
                r.frame:Destroy()
            end)
        end
    end
    el.sendCount.Text = #S.plan.senders .. " sender" .. (#S.plan.senders == 1 and "" or "s")
end

function UI.updateSenderRows()
    for _, s in ipairs(S.plan.senders) do
        local key = H.lower(s.name)
        local r = UI.rows[key]
        if r then
            local st = S.statuses[key]
            local phase, color, info
            if not st or st.stale then
                phase, color, info = (st and st.phase == "done") and "DONE" or "OFFLINE", (st and st.phase == "done") and TH.Good or TH.Dim, "script not running"
            else
                local ph = PHASE[st.phase] or PHASE.idle
                phase, color = ph.title, ph.color
                info = (st.sent or 0) .. " sent · " .. (st.remaining or 0) .. " left"
                if H.findPlayer(s.name) then
                    info = "● here · " .. info
                end
            end
            if r.pill.Text ~= phase then
                r.pill.Text = phase
                r.pill.TextColor3 = color
                r.pill.BackgroundColor3 = color
                UI.tween(r.stroke, MOTION.Base, { Color = color:Lerp(TH.Stroke, 0.55) })
                r.avatar.ring.Color = color
            end
            r.info.Text = info
        end
    end
end

-- ── Items page ──────────────────────────────────────────────
-- segmented control with a sliding highlight
function UI.segmented(parent, options, getValue, onPick, props)
    local seg = UI.new("Frame", { BackgroundColor3 = TH.Panel, Size = UDim2.fromOffset(#options * 70 + 6, 36),
        Parent = parent }, { UI.corner(10), UI.stroke() })
    for k, v in pairs(props or {}) do
        seg[k] = v
    end
    local hi = UI.new("Frame", { BackgroundColor3 = TH.Accent, Position = UDim2.fromOffset(3, 3),
        Size = UDim2.fromOffset(70, 30), Parent = seg }, { UI.corner(8) })
    local labels = {}
    for i, opt in ipairs(options) do
        local b = UI.new("TextButton", { AutoButtonColor = false, BackgroundTransparency = 1, Text = opt,
            TextSize = 12, Font = TH.Bold, TextColor3 = TH.Sub, Position = UDim2.fromOffset(3 + (i - 1) * 70, 3),
            Size = UDim2.fromOffset(70, 30), ZIndex = 2, Parent = seg })
        labels[opt] = { button = b, index = i }
        UI.track(b.Activated:Connect(function()
            onPick(opt)
        end))
    end
    local api = {}
    function api.paint()
        local cur = getValue()
        for opt, l in pairs(labels) do
            local on = opt == cur
            UI.tween(l.button, MOTION.Base, { TextColor3 = on and TH.Text or TH.Sub })
            if on then
                UI.tween(hi, MOTION.Spring, { Position = UDim2.fromOffset(3 + (l.index - 1) * 70, 3) })
            end
        end
    end
    api.paint()
    return api
end

function UI.buildItems(page)
    local el = UI.el
    -- toolbar: search · segmented filter · "send everything" switch
    local top = UI.new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 36), Parent = page })
    el.search = UI.input(top, "Search items…", { Size = UDim2.new(1, -440, 1, 0) })
    UI.track(el.search:GetPropertyChangedSignal("Text"):Connect(function()
        UI.search = H.lower(el.search.Text)
        UI.gridDirty = true
    end))
    el.seg = UI.segmented(top, { "All", "Units", "Items" }, function()
        return UI.filter
    end, function(v)
        UI.filter = v
        UI.gridDirty = true
        el.seg.paint()
    end, { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -206, 0, 0) })

    el.allToggle = UI.new("TextButton", { AutoButtonColor = false, AnchorPoint = Vector2.new(1, 0),
        Position = UDim2.fromScale(1, 0), Size = UDim2.fromOffset(196, 36), BackgroundColor3 = TH.Panel,
        Text = "", Parent = top }, { UI.corner(10), UI.stroke() })
    UI.press(el.allToggle)
    el.allLabel = UI.label("Send everything", 12, TH.Sub, TH.Bold, { Position = UDim2.fromOffset(14, 0),
        Size = UDim2.new(1, -70, 1, 0), Parent = el.allToggle })
    el.allTrack = UI.new("Frame", { AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -12, 0.5, 0),
        Size = UDim2.fromOffset(38, 20), BackgroundColor3 = TH.Elevated, Parent = el.allToggle }, { UI.corner() })
    el.allKnob = UI.new("Frame", { AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 3, 0.5, 0),
        Size = UDim2.fromOffset(14, 14), BackgroundColor3 = TH.Sub, Parent = el.allTrack }, { UI.corner() })
    UI.track(el.allToggle.Activated:Connect(function()
        S.plan.all = not S.plan.all
        FS.savePlan()
        UI.paintAll()
        UI.gridDirty = true
        UI.toast(S.plan.all and "Sending EVERY tradeable item" or "Sending only ticked items", S.plan.all and "Bad" or "Good")
    end))

    el.grid = UI.scroller(page, { Position = UDim2.fromOffset(0, 48), Size = UDim2.new(1, 0, 1, -100) })
    UI.new("UIGridLayout", { CellSize = UDim2.fromOffset(122, 168), CellPadding = UDim2.fromOffset(10, 10),
        SortOrder = Enum.SortOrder.LayoutOrder, Parent = el.grid })
    UI.new("UIPadding", { PaddingTop = UDim.new(0, 4), PaddingLeft = UDim.new(0, 4), PaddingBottom = UDim.new(0, 8),
        Parent = el.grid })
    el.gridEmpty = UI.label("Nothing here - units placed on your plot are hidden", 13, TH.Dim, TH.Font, {
        Position = UDim2.fromOffset(0, 90), Size = UDim2.new(1, 0, 0, 20), TextXAlignment = Enum.TextXAlignment.Center,
        Visible = false, Parent = page })

    -- footer: summary pill + actions
    local foot = UI.new("Frame", { BackgroundTransparency = 1, AnchorPoint = Vector2.new(0, 1),
        Position = UDim2.fromScale(0, 1), Size = UDim2.new(1, 0, 0, 40), Parent = page })
    local pill = UI.new("Frame", { BackgroundColor3 = TH.Panel, Size = UDim2.new(1, -262, 1, 0), Parent = foot },
        { UI.corner(10), UI.stroke() })
    el.sumDot = UI.new("Frame", { AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 14, 0.5, 0),
        Size = UDim2.fromOffset(8, 8), BackgroundColor3 = TH.Dim, Parent = pill }, { UI.corner() })
    el.itemSummary = UI.label("", 12, TH.Text, TH.Bold, { Position = UDim2.fromOffset(30, 0),
        Size = UDim2.new(1, -40, 1, 0), Parent = pill })
    UI.button(foot, "Clear", TH.Panel, { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -130, 0, 0),
        Size = UDim2.fromOffset(122, 40), TextColor3 = TH.Bad }, function()
        S.plan.rules = {}
        FS.savePlan()
        UI.gridDirty = true
        UI.toast("Selection cleared", "Bad")
    end)
    UI.button(foot, "Tick all shown", TH.Accent, { AnchorPoint = Vector2.new(1, 0), Position = UDim2.fromScale(1, 0),
        Size = UDim2.fromOffset(122, 40) }, function()
        local n = 0
        for _, t in pairs(UI.tiles) do
            if t.visible and t.group.tradeable then
                S.plan.rules[t.group.name] = "all"
                n = n + 1
            end
        end
        FS.savePlan()
        UI.gridDirty = true
        UI.toast("Ticked " .. n .. " items", "Good")
    end)
    UI.paintAll()
end

function UI.paintFilters()
    if UI.el.seg then
        UI.el.seg.paint()
    end
end

function UI.paintAll()
    local el = UI.el
    local on = S.plan.all
    UI.tween(el.allTrack, MOTION.Base, { BackgroundColor3 = on and TH.Bad or TH.Elevated })
    UI.tween(el.allKnob, MOTION.Spring, { Position = on and UDim2.new(1, -17, 0.5, 0) or UDim2.new(0, 3, 0.5, 0),
        BackgroundColor3 = on and TH.Text or TH.Sub })
    el.allLabel.Text = on and "Sending EVERYTHING" or "Send everything"
    UI.tween(el.allLabel, MOTION.Base, { TextColor3 = on and TH.Bad or TH.Sub })
end

-- first colour of a rarity gradient, for text accents
function UI.rarityColor(cfg)
    local ok, c = pcall(function()
        return cfg.gradient.Keypoints[math.ceil(#cfg.gradient.Keypoints / 2)].Value
    end)
    return ok and c or TH.Sub
end

-- one tile per item name (units placed on the plot are left out)
function UI.tileFor(g)
    local t = UI.tiles[g.name]
    if t then
        t.group = g
        return t
    end
    local f = UI.new("Frame", { BackgroundColor3 = TH.Panel, Parent = UI.el.grid }, { UI.corner(12), UI.new("UIScale", {}) })
    local st = UI.stroke(TH.Stroke)
    st.Parent = f
    -- icon well with a soft rarity glow behind the game's icon
    local well = UI.new("Frame", { BackgroundColor3 = TH.Bg, Position = UDim2.fromOffset(8, 8),
        Size = UDim2.new(1, -16, 0, 100), ClipsDescendants = true, Parent = f }, { UI.corner(10) })
    local glow = UI.new("Frame", { Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.new(1, 1, 1),
        BackgroundTransparency = 0.82, Parent = well }, { UI.corner(10) })
    if g.cfg.gradient then
        UI.new("UIGradient", { Color = g.cfg.gradient, Rotation = 90,
            Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(1, 0) }),
            Parent = glow })
    end
    local holder = UI.new("Frame", { BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(92, 92), Parent = well })
    UI.label(string.upper(string.sub(g.name, 1, 2)), 24, TH.Text, TH.Bold, { Size = UDim2.fromScale(1, 1),
        TextXAlignment = Enum.TextXAlignment.Center, Name = "Placeholder", Parent = holder })
    -- amount badge (top-left)
    local badge = UI.new("TextLabel", { BackgroundColor3 = TH.Bg, BackgroundTransparency = 0.15,
        Position = UDim2.fromOffset(6, 6), Size = UDim2.fromOffset(0, 20), AutomaticSize = Enum.AutomaticSize.X,
        Text = "", TextSize = 11, Font = TH.Bold, TextColor3 = TH.Text, ZIndex = 4, Parent = well },
        { UI.corner(), UI.new("UIPadding", { PaddingLeft = UDim.new(0, 7), PaddingRight = UDim.new(0, 7) }) })
    local badgeStroke = UI.stroke(UI.rarityColor(g.cfg), 0.3)
    badgeStroke.Parent = badge
    -- selection tint + check
    local tint = UI.new("Frame", { Size = UDim2.fromScale(1, 1), BackgroundColor3 = TH.Accent, BackgroundTransparency = 1,
        ZIndex = 3, Parent = well }, { UI.corner(10) })
    local check = UI.new("TextLabel", { AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, -6, 1, -6),
        Size = UDim2.fromOffset(22, 22), BackgroundColor3 = TH.Accent, Text = "✓", TextSize = 13, Font = TH.Bold,
        TextColor3 = TH.Text, ZIndex = 5, Visible = false, Parent = well }, { UI.corner(), UI.new("UIScale", {}) })
    -- name + sub line
    local name = UI.label(g.name, 12, TH.Text, TH.Bold, { Position = UDim2.fromOffset(8, 113),
        Size = UDim2.new(1, -16, 0, 15), TextXAlignment = Enum.TextXAlignment.Center, Parent = f })
    local sub = UI.label("", 11, TH.Sub, TH.Bold, { Position = UDim2.fromOffset(8, 130),
        Size = UDim2.new(1, -16, 0, 28), TextXAlignment = Enum.TextXAlignment.Center, Parent = f })
    -- stepper pill (visible when selected): − value +
    local stepper = UI.new("Frame", { BackgroundColor3 = TH.Bg, Position = UDim2.fromOffset(8, 132),
        Size = UDim2.new(1, -16, 0, 28), Visible = false, ZIndex = 6, Parent = f }, { UI.corner() })
    local stStroke = UI.stroke(TH.Accent, 0.4)
    stStroke.Parent = stepper
    local function round(text, x)
        local b = UI.new("TextButton", { AutoButtonColor = false, Text = text, TextSize = 15, Font = TH.Bold,
            TextColor3 = TH.Text, BackgroundColor3 = TH.Accent, AnchorPoint = Vector2.new(x, 0.5),
            Position = UDim2.new(x, x == 0 and 3 or -3, 0.5, 0), Size = UDim2.fromOffset(22, 22), ZIndex = 7,
            Parent = stepper }, { UI.corner() })
        UI.press(b)
        return b
    end
    local minus = round("–", 0)
    local plus = round("+", 1)
    local amount = UI.new("TextBox", { BackgroundTransparency = 1, Text = "ALL", TextSize = 12, Font = TH.Bold,
        TextColor3 = TH.Text, Position = UDim2.fromOffset(27, 0), Size = UDim2.new(1, -54, 1, 0),
        ClearTextOnFocus = true, ZIndex = 7, Parent = stepper })
    local hit = UI.new("TextButton", { BackgroundTransparency = 1, Text = "", Size = UDim2.new(1, 0, 0, 128),
        ZIndex = 8, Parent = f })
    t = { frame = f, stroke = st, well = well, holder = holder, tint = tint, badge = badge, name = name, sub = sub,
        stepper = stepper, amount = amount, check = check, group = g, visible = true, glow = glow }
    UI.tiles[g.name] = t

    local function setRule(v)
        S.plan.rules[t.group.name] = v
        FS.savePlan()
        UI.paintTile(t, true)
    end
    UI.track(hit.Activated:Connect(function()
        if not t.group.tradeable then
            UI.toast(t.group.name .. " can't be traded", "Bad")
            return
        end
        if S.plan.all then
            UI.toast("turn off Send everything to pick items", "Bad")
            return
        end
        if S.plan.rules[t.group.name] then
            setRule(nil)
        else
            setRule("all")
        end
    end))
    local sc = f:FindFirstChildOfClass("UIScale")
    UI.track(hit.MouseEnter:Connect(function()
        UI.tween(sc, MOTION.Fast, { Scale = 1.03 })
        UI.tween(glow, MOTION.Fast, { BackgroundTransparency = 0.7 })
    end))
    UI.track(hit.MouseLeave:Connect(function()
        UI.tween(sc, MOTION.Base, { Scale = 1 })
        UI.tween(glow, MOTION.Base, { BackgroundTransparency = 0.82 })
    end))
    UI.track(minus.Activated:Connect(function()
        local cur = S.plan.rules[t.group.name]
        local n = (cur == "all") and t.group.total or (tonumber(cur) or 1)
        n = n - 1
        setRule(n > 0 and n or nil)
    end))
    UI.track(plus.Activated:Connect(function()
        local cur = S.plan.rules[t.group.name]
        if cur == "all" then
            return
        end
        local n = (tonumber(cur) or 0) + 1
        setRule(n >= t.group.total and "all" or n)
    end))
    UI.track(amount.FocusLost:Connect(function()
        local txt = H.lower(amount.Text)
        if txt == "" or txt == "all" or txt == "a" or txt == "max" then
            setRule("all")
            return
        end
        local n = tonumber(txt)
        if not n then
            local ok, v = pcall(M.NF.ParseCompact, txt)
            n = ok and v or nil
        end
        if not n or n <= 0 then
            setRule(nil)
        else
            n = math.floor(n)
            setRule(n >= t.group.total and "all" or n)
        end
    end))
    if M.EntryIcon then
        ICON.request(g.name, g.keys[1] and g.keys[1].key, holder)
    end
    sc.Scale = 0.85
    UI.tween(sc, MOTION.Spring, { Scale = 1 })
    return t
end

function UI.paintTile(t, animate)
    local g = t.group
    local rule = S.plan.all and (g.tradeable and "all" or nil) or S.plan.rules[g.name]
    local on = rule ~= nil
    -- amount badge + sub line
    if g.kind == "Unit" then
        t.badge.Text = "×" .. H.fmt(g.total)
        local best = g.keys[1] and g.keys[1].income or 0
        t.sub.Text = "$" .. H.fmt(best) .. "/s"
        t.sub.TextColor3 = TH.Good
    else
        t.badge.Text = "x" .. H.fmt(g.total)
        t.sub.Text = tostring(g.cfg.rarity or g.kind)
        t.sub.TextColor3 = UI.rarityColor(g.cfg)
    end
    if not g.tradeable then
        t.sub.Text = "can't trade"
        t.sub.TextColor3 = TH.Bad
    end
    t.frame.BackgroundTransparency = g.tradeable and 0 or 0.45
    t.sub.Visible = not (on and not S.plan.all)
    t.stepper.Visible = on and not S.plan.all
    if on and not S.plan.all and not t.amount:IsFocused() then
        t.amount.Text = (rule == "all") and ("ALL · " .. H.fmt(g.total)) or (H.fmt(tonumber(rule) or 0) .. " / " .. H.fmt(g.total))
    end
    local wasOn = t.check.Visible
    t.check.Visible = on
    UI.tween(t.tint, MOTION.Base, { BackgroundTransparency = on and 0.86 or 1 })
    UI.tween(t.stroke, MOTION.Base, { Color = on and TH.Accent or TH.Stroke })
    t.stroke.Thickness = on and 2 or 1
    if animate and on and not wasOn then
        local sc = t.check:FindFirstChildOfClass("UIScale")
        sc.Scale = 0.2
        UI.tween(sc, MOTION.Spring, { Scale = 1 })
        local fs = t.frame:FindFirstChildOfClass("UIScale")
        fs.Scale = 0.94
        UI.tween(fs, MOTION.Spring, { Scale = 1 })
    end
end

function UI.renderGrid()
    UI.gridDirty = false
    local groups = H.groups()
    local seen = {}
    local selItems, selCount, shown = 0, 0, 0
    for i, g in ipairs(groups) do
        seen[g.name] = true
        local t = UI.tileFor(g)
        local passFilter = UI.filter == "All" or (UI.filter == "Units" and g.kind == "Unit")
            or (UI.filter == "Items" and g.kind ~= "Unit")
        local passSearch = UI.search == "" or string.find(H.lower(g.name), UI.search, 1, true) ~= nil
        t.visible = passFilter and passSearch
        t.frame.Visible = t.visible
        t.frame.LayoutOrder = i
        if t.visible then
            shown = shown + 1
        end
        UI.paintTile(t, false)
        local rule = S.plan.all and (g.tradeable and "all" or nil) or S.plan.rules[g.name]
        if rule then
            selItems = selItems + 1
            selCount = selCount + ((rule == "all") and g.total or math.min(tonumber(rule) or 0, g.total))
        end
    end
    for name, t in pairs(UI.tiles) do
        if not seen[name] then
            UI.tiles[name] = nil
            t.frame:Destroy()
        end
    end
    UI.el.gridEmpty.Visible = shown == 0
    local other = 0
    for name in pairs(S.plan.rules) do
        if not seen[name] then
            other = other + 1
        end
    end
    UI.el.itemSummary.Text = (S.plan.all and "EVERYTHING tradeable  ·  " or "") .. selItems .. " picked  ·  "
        .. H.fmt(selCount) .. " pcs" .. (other > 0 and ("  ·  +" .. other .. " from other screens") or "")
    UI.el.sumDot.BackgroundColor3 = (selItems > 0 or S.plan.all) and (S.plan.all and TH.Bad or TH.Good) or TH.Dim
end

-- deliver finished game icons into their tiles; the game's own text labels (count / income
-- boxes) and the "equipped" tick are hidden - the tile draws its own badge instead
function UI.deliverIcons()
    while #ICON.done > 0 do
        local d = table.remove(ICON.done, 1)
        local holder = d.job.holder
        if holder and holder.Parent then
            if d.icon then
                local ok = pcall(function()
                    for _, desc in ipairs(d.icon:GetDescendants()) do
                        if desc:IsA("TextLabel") or desc:IsA("TextButton") then
                            desc.Visible = false
                        elseif desc.Name == "Equipped" and desc:IsA("GuiObject") then
                            desc.Visible = false
                        end
                    end
                    d.icon.AnchorPoint = Vector2.new(0.5, 0.5)
                    d.icon.Position = UDim2.fromScale(0.5, 0.5)
                    d.icon.Size = UDim2.fromScale(1, 1)
                    d.icon.Parent = holder
                end)
                if ok then
                    local ph = holder:FindFirstChild("Placeholder")
                    if ph then
                        ph:Destroy()
                    end
                end
            elseif d.err and not UI.iconErrLogged then
                UI.iconErrLogged = true
                log("game icon failed (" .. tostring(d.err) .. ") - keeping simple tiles", "Warn")
            end
        end
    end
end

-- ── Run page ────────────────────────────────────────────────
function UI.buildRun(page)
    local el = UI.el
    UI.new("UIListLayout", { Padding = UDim.new(0, 10), SortOrder = Enum.SortOrder.LayoutOrder, Parent = page })
    -- hero
    local hero = UI.new("Frame", { BackgroundColor3 = TH.Panel, Size = UDim2.new(1, 0, 0, 86), LayoutOrder = 1, Parent = page },
        { UI.corner(12), UI.stroke() })
    el.orb = UI.new("Frame", { Position = UDim2.fromOffset(18, 20), Size = UDim2.fromOffset(46, 46), BackgroundTransparency = 1,
        Parent = hero })
    el.ring = UI.new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(1, 1),
        BackgroundTransparency = 1, Parent = el.orb }, { UI.corner(), UI.new("UIScale", {}) })
    el.ringStroke = UI.new("UIStroke", { Thickness = 2, Color = TH.Dim, Parent = el.ring })
    el.ringScale = el.ring:FindFirstChildOfClass("UIScale")
    el.core = UI.new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5),
        Size = UDim2.fromOffset(18, 18), BackgroundColor3 = TH.Dim, Parent = el.orb }, { UI.corner() })
    el.phase = UI.label("IDLE", 20, TH.Text, TH.Bold, { Position = UDim2.fromOffset(80, 18), Size = UDim2.new(1, -260, 0, 26), Parent = hero })
    el.phaseMsg = UI.label("", 12, TH.Sub, TH.Font, { Position = UDim2.fromOffset(80, 46), Size = UDim2.new(1, -260, 0, 16), Parent = hero })
    el.startBtn = UI.button(hero, "START", TH.Good, { AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -16, 0.5, 0),
        Size = UDim2.fromOffset(150, 46), TextSize = 15, TextColor3 = TH.Bg }, function()
        if not S.plan.running then
            if not S.plan.receiver then
                UI.toast("set a receiver first", "Bad")
                UI.select("Receiver")
                return
            end
            if #S.plan.senders == 0 then
                UI.toast("add at least one sender", "Bad")
                UI.select("Senders")
                return
            end
            local picked = S.plan.all or next(S.plan.rules) ~= nil
            if not picked then
                UI.toast("pick items to send first", "Bad")
                UI.select("Items")
                return
            end
        end
        S.plan.running = not S.plan.running
        FS.savePlan()
        log(S.plan.running and "START - every screen in the plan begins" or "STOP", S.plan.running and "Good" or "Bad")
        UI.toast(S.plan.running and "Started on every screen" or "Stopped", S.plan.running and "Good" or "Bad")
    end)
    el.startSweep = UI.new("UIGradient", { Rotation = 0, Parent = el.startBtn })

    -- settings
    local set = UI.new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 38), LayoutOrder = 2, Parent = page })
    local waitRow = UI.new("Frame", { BackgroundColor3 = TH.Panel, Size = UDim2.new(0.5, -5, 1, 0), Parent = set },
        { UI.corner(8), UI.stroke() })
    UI.label("Wait in server", 12, TH.Text, TH.Font, { Position = UDim2.fromOffset(12, 0), Size = UDim2.new(1, -130, 1, 0), Parent = waitRow })
    el.waitBox = UI.new("TextBox", { AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -8, 0.5, 0),
        Size = UDim2.fromOffset(70, 26), BackgroundColor3 = TH.Bg, Text = tostring(S.plan.wait) .. "s", TextSize = 12,
        Font = TH.Bold, TextColor3 = TH.Text, ClearTextOnFocus = true, Parent = waitRow }, { UI.corner(6) })
    UI.track(el.waitBox.FocusLost:Connect(function()
        local n = tonumber((string.gsub(el.waitBox.Text, "%D", "")))
        if n then
            S.plan.wait = math.clamp(n, 0, 900)
            FS.savePlan()
        end
        el.waitBox.Text = tostring(S.plan.wait) .. "s"
    end))
    local followHolder = UI.new("Frame", { BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0),
        Position = UDim2.fromScale(1, 0), Size = UDim2.new(0.5, -5, 1, 0), Parent = set })
    el.followToggle = UI.toggle(followHolder, "Senders join receiver's server", function()
        return S.plan.follow
    end, function(v)
        S.plan.follow = v
        FS.savePlan()
    end)

    -- progress list
    UI.section(page, "Progress", 3)
    el.progress = UI.scroller(page, { Size = UDim2.new(1, 0, 0, 200), LayoutOrder = 4 })
    UI.new("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder, Parent = el.progress })
    el.progRows = {}

    -- log
    local logBox = UI.new("Frame", { BackgroundColor3 = TH.Panel, Size = UDim2.new(1, 0, 0, 92), LayoutOrder = 5, Parent = page },
        { UI.corner(8), UI.stroke(), UI.pad(8) })
    el.logLines = {}
    for i = 1, 5 do
        el.logLines[i] = UI.label("", 11, TH.Sub, TH.Mono, { Position = UDim2.fromOffset(0, (i - 1) * 15),
            Size = UDim2.new(1, 0, 0, 15), Parent = logBox })
    end
end

function UI.updateRun()
    local el = UI.el
    local ph = PHASE[S.phase] or PHASE.idle
    if el.phase.Text ~= ph.title then
        el.phase.Text = ph.title
        el.phase.TextTransparency = 1
        UI.tween(el.phase, MOTION.Slow, { TextTransparency = 0 })
        UI.tween(el.core, MOTION.Base, { BackgroundColor3 = ph.color })
        el.ringStroke.Color = ph.color
        UI.tween(el.sideDot, MOTION.Base, { BackgroundColor3 = ph.color })
        el.sweep.Color = ColorSequence.new({ ColorSequenceKeypoint.new(0, TH.Stroke),
            ColorSequenceKeypoint.new(0.5, ph.color), ColorSequenceKeypoint.new(1, TH.Stroke) })
    end
    el.phaseMsg.Text = S.role == "editor" and "this screen only edits the plan" or tostring(S.msg)
    el.sidePhase.Text = ph.title
    el.sidePhase.TextColor3 = ph.color
    local running = S.plan.running
    if UI.lastRunning ~= running then
        UI.lastRunning = running
        el.startBtn.Text = running and "STOP" or "START"
        UI.tween(el.startBtn, MOTION.Base, { BackgroundColor3 = running and TH.Bad or TH.Good })
        el.followToggle.paint()
    end
    -- role chip
    local roleText = string.upper(S.role)
    if el.roleChip.Text ~= roleText then
        el.roleChip.Text = roleText
        local c = S.role == "receiver" and TH.Accent or (S.role == "sender" and TH.Purple or TH.Sub)
        el.roleChip.TextColor3 = c
        el.roleChip.BackgroundColor3 = c
    end
    -- progress rows (receiver first)
    local list = {}
    if S.plan.receiver then
        table.insert(list, { name = S.plan.receiver.name, recv = true })
    end
    for _, s in ipairs(S.plan.senders) do
        table.insert(list, { name = s.name })
    end
    local keep = {}
    for i, item in ipairs(list) do
        local key = H.lower(item.name)
        keep[key] = true
        local r = el.progRows[key]
        if not r then
            local f = UI.new("Frame", { BackgroundColor3 = TH.Panel, Size = UDim2.new(1, -6, 0, 26), Parent = el.progress }, { UI.corner(6) })
            local dot = UI.new("Frame", { Position = UDim2.fromOffset(10, 9), Size = UDim2.fromOffset(8, 8), BackgroundColor3 = TH.Dim,
                Parent = f }, { UI.corner() })
            local nm = UI.label(item.name .. (item.recv and "  (receiver)" or ""), 12, TH.Text, TH.Bold,
                { Position = UDim2.fromOffset(26, 0), Size = UDim2.new(0.45, 0, 1, 0), Parent = f })
            local info = UI.label("", 11, TH.Sub, TH.Font, { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -10, 0, 0),
                Size = UDim2.new(0.55, -20, 1, 0), TextXAlignment = Enum.TextXAlignment.Right, Parent = f })
            r = { frame = f, dot = dot, info = info, name = nm }
            el.progRows[key] = r
        end
        r.frame.LayoutOrder = i
        local st = S.statuses[key]
        if key == H.lower(LP.Name) then
            st = { phase = S.phase, msg = S.msg, sent = S.sent }
        end
        local p = (st and not st.stale) and (PHASE[st.phase] or PHASE.idle) or PHASE.idle
        r.dot.BackgroundColor3 = (st and not st.stale) and p.color or TH.Dim
        if not st or st.stale then
            r.info.Text = (st and st.phase == "done") and "done" or "offline"
        else
            r.info.Text = p.title .. " · " .. tostring(st.msg or "") .. (item.recv and "" or (" · sent " .. tostring(st.sent or 0)))
        end
    end
    for key, r in pairs(el.progRows) do
        if not keep[key] then
            el.progRows[key] = nil
            r.frame:Destroy()
        end
    end
    -- log
    for i = 1, 5 do
        local l = S.logLines[i]
        el.logLines[i].Text = l and l.text or ""
        el.logLines[i].TextColor3 = l and (l.kind == "Bad" and TH.Bad or (l.kind == "Good" and TH.Good or TH.Sub)) or TH.Sub
    end
end

-- ── frame loop ──────────────────────────────────────────────
function UI.frame(dt)
    if not UI.gui or not UI.gui.Parent then
        UI.destroy()
        return
    end
    local el = UI.el
    local t = os.clock()
    local speed = (S.phase == "trading" or S.phase == "receiving") and 1.6 or (S.phase == "waiting" and 0.9 or 0.4)
    local wave = (t * speed) % 1
    el.ringScale.Scale = 0.55 + wave * 0.75
    el.ringStroke.Transparency = wave
    el.sweep.Rotation = (el.sweep.Rotation + (S.plan.running and 160 or 40) * dt) % 360
    if S.plan.running then
        el.startSweep.Offset = Vector2.new(math.sin(t * 2) * 0.5, 0)
    end
    UI.deliverIcons()
    if t >= UI.refreshAt then
        UI.refreshAt = t + 0.5
        local ok, err = pcall(function()
            UI.updateRun()
            UI.updateSenderRows()
            if UI.tab and UI.tab.name == "Items" and (UI.gridDirty or (UI.gridAt or 0) < t) then
                UI.gridAt = t + 5
                UI.renderGrid()
            end
            if UI.lastPlanRev ~= S.planRev then
                UI.lastPlanRev = S.planRev
                UI.renderSenders()
                UI.paintAll()
                el.waitBox.Text = tostring(S.plan.wait) .. "s"
                el.followToggle.paint()
                if S.plan.receiver then
                    el.recvBox.Text = S.plan.receiver.name
                    UI.renderReceiver(S.plan.receiver, true)
                end
                UI.gridDirty = true
            end
        end)
        if not ok then
            UI.err = (UI.err or 0) + 1
            if UI.err % 20 == 1 then
                log("ui error: " .. tostring(err), "Bad")
            end
        end
    end
end

function UI.destroy()
    for _, c in ipairs(UI.conns) do
        pcall(function()
            c:Disconnect()
        end)
    end
    table.clear(UI.conns)
    if UI.gui then
        local g = UI.gui
        UI.gui = nil
        pcall(function()
            g:Destroy()
        end)
    end
end

-- ════════════════════════════════════════════════════════════
-- START
-- ════════════════════════════════════════════════════════════
FS.ensure()
FS.loadPlan()
log("loaded · " .. LP.Name .. " · PlaceId " .. game.PlaceId .. (game.PrivateServerId ~= "" and " · private server" or ""))
do
    local ok, err = pcall(UI.build)
    if not ok then
        log("ui build error: " .. tostring(err), "Bad")
    end
end
if M.EntryIcon then
    task.spawn(ICON.workerLoop)
end
task.spawn(fileLoop)
task.spawn(engineLoop)
task.spawn(antiAfk)
UI.toast("Trade Hub loaded · RightCtrl hides", "Good")
