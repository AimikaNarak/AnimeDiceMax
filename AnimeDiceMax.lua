-- Anime Dice · Chain Builder
-- Run through Loader.lua (config lives there in getgenv().AnimeDice).
--
-- Everything below was read from the game's own server modules, which ship to the client in
-- ReplicatedStorage.Framework.Features (dump 2026-10-19):
--   roll   RollService.RF.RollDice      server allows 1 roll per "Roll Duration" buff seconds
--   plot   PlotService.RE.CollectBalance(slot) / EquipBest() / LevelUpSlot(slot)
--   sell   SellService.RF.SellInventory({keys})   server skips plotted + locked units
--   shop   Network.RE.BuyUpgrade(name) · DiceShopService.RE.BuyDice(name)
--   reb    RebirthService.RE.Rebirth() / AddStat(name)
--   tower  Towers.RF.PlayTower(name) then CompleteTowerFloor() until "ended" (server simulates)
--   trade  TradeService: RequestTrade(plr) → RespondToRequest(true) → ChangeOffer(key, n)
--          → AdvanceTrade (ready) → AdvanceTrade (accept) → 3s countdown → Ended "Completed"
-- Chain accounts coordinate through files in workspace/AnimeDice/chain (all screens must run on
-- the same PC so they share the Potassium workspace folder).

local CONFIG_DEFAULTS = {
    Farm = { Start = true, Graphics = 1, LevelUnits = true, AutoItems = true },
    Sell = { FreeSlots = 10, KeepIncomeAbove = 0 },
    Rebirth = { Stats = { "Money" }, StopAt = 0 },
    Tower = { Enabled = true, Pick = "best", Only = {}, Infinity = true },
    TicketShop = {},
    Chain = {
        Enabled = false,
        Order = {},
        Units = {},
        TopUnits = 2,
        SendGear = true,
        MaxedWhen = { "Rebirth", "Dice", "Upgrades" },
        UpgradeGiveUpMin = 0,
        LeaveWhenDone = true,
    },
    Trade = { HostHop = true, FreeSlots = 1, WaitAfterJoin = 180 },
    Manager = "Auto",
}

-- Hardcoded tuning (same for every account)
local K = {
    MAIN_URL = "https://raw.githubusercontent.com/AimikaNarak/AnimeDiceMax/main/AnimeDiceMax.lua",

    CHAIN_DIR = "AnimeDice/chain",
    LOG_DIR = "AnimeDice/logs",
    SPEND_SHARE = 0.25,      -- before max rebirth, only buy things costing <= 25% of the next rebirth
    LEVEL_PAYBACK = 600,     -- level a plotted unit only if the extra income repays it within 600s
    STATE_FRESH = 90,        -- a chain file older than this = that screen is offline
    TOWER_CAP = 500,         -- simulation cap for endless towers
    HOP_COOLDOWN = 60,
}

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local TeleportService = game:GetService("TeleportService")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Lighting = game:GetService("Lighting")

local LP = Players.LocalPlayer
while not LP do
    task.wait()
    LP = Players.LocalPlayer
end
if not game:IsLoaded() then
    game.Loaded:Wait()
end

-- ── config merge ────────────────────────────────────────────
local CFG = {}
do
    local user = (getgenv and getgenv().AnimeDice) or {}
    for section, defaults in pairs(CONFIG_DEFAULTS) do
        local given = user[section]
        if type(defaults) == "table" and #defaults == 0 and next(defaults) ~= nil then
            CFG[section] = {}
            for k, v in pairs(defaults) do
                if type(given) == "table" and given[k] ~= nil then
                    CFG[section][k] = given[k]
                else
                    CFG[section][k] = v
                end
            end
        else
            -- plain sections: TicketShop (list) and Manager (string)
            if type(defaults) == "string" then
                CFG[section] = type(given) == "string" and given or defaults
            else
                CFG[section] = type(given) == "table" and given or defaults
            end
        end
    end
    if #CFG.Chain.MaxedWhen == 0 then
        CFG.Chain.MaxedWhen = { "Rebirth", "Dice", "Upgrades" }
    end
end

-- ── single instance: a re-run (or queue_on_teleport + autoexec) replaces the old copy ──
local TOKEN = HttpService:GenerateGUID(false)
LP:SetAttribute("AnimeDiceRun", TOKEN)
local function alive()
    return LP:GetAttribute("AnimeDiceRun") == TOKEN
end

-- ── state ───────────────────────────────────────────────────
local S = {
    farm = CFG.Farm.Start,
    towerOn = CFG.Tower.Enabled,
    chainOn = CFG.Chain.Enabled,
    pauseRoll = false,
    pauseSell = false,
    selling = false,
    joinedAt = os.time(),
    startClock = os.clock(),
    logLines = {},
    missing = {},
    rollTimes = {},
    rollFails = 0,
    lastSell = "",
    lastSpend = "",
    lastUpgradeBuy = os.time(),
    rebirthTarget = 0,
    maxRebirth = 0,
    topDice = nil,
    upgradeTotal = 0,
    tower = { name = "-", floor = 0, predicted = 0, runs = 0, cycle = 0, msg = "off" },
    chain = { role = "-", phase = "farm", target = nil, msg = "off", done = false, myIndex = nil,
        lastTp = 0, lastHop = 0, lastHostCheck = 0, builderHere = false, builderName = nil, builderIdx = nil },
    afk = "pending",
    rejoin = "not queued",
    codesDone = false,
}

-- ── logging ─────────────────────────────────────────────────
local function log(msg, kind)
    local line = os.date("%H:%M:%S") .. " " .. tostring(msg)
    print("[AnimeDice] " .. line)
    table.insert(S.logLines, 1, { text = line, kind = kind })
    if #S.logLines > 6 then
        table.remove(S.logLines)
    end
    if appendfile and isfolder then
        pcall(function()
            if not isfolder("AnimeDice") then makefolder("AnimeDice") end
            if not isfolder(K.LOG_DIR) then makefolder(K.LOG_DIR) end
            appendfile(K.LOG_DIR .. "/" .. LP.Name .. ".log", line .. "\n")
        end)
    end
end

-- Executor threads run at RobloxScript identity, which may not require game ModuleScripts that
-- were never loaded before. Drop to identity 2 around every require of a game module.
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
        error("[AnimeDice] ReplicatedStorage.Framework not found - wrong game? PlaceId " .. game.PlaceId)
    end
    local t0 = os.clock()
    while not fw:GetAttribute("IsLoaded") and os.clock() - t0 < 60 do
        task.wait(0.5)
    end
    local F = fw:WaitForChild("Features", 30)
    local function req(inst, label)
        local ok, res = pcall(asGame, require, inst)
        if not ok then
            error("[AnimeDice] require " .. label .. " failed: " .. tostring(res), 0)
        end
        return res
    end
    M.Data = req(F.Data.DataController, "DataController")
    M.Buff = req(F.Buffs.BuffController, "BuffController")
    M.Entry = req(F.Inventory.EntryRegistry, "EntryRegistry")
    M.Dice = req(F.Rolling.Dice, "Dice")
    M.Upgrades = req(F.Upgrades.Upgrades, "Upgrades")
    M.Tree = req(F.Upgrades.TreeStructure, "TreeStructure")
    M.Rebirths = req(F.Rebirth.Rebirths, "Rebirths")
    M.RStats = req(F.Rebirth.RebirthStatsConfig, "RebirthStatsConfig")
    M.PlotConfig = req(F.Plot.PlotConfig, "PlotConfig")
    M.UnitUtil = req(F.Inventory.Kinds.Unit.UnitUtil, "UnitUtil")
    M.Towers = req(F.Towers.Towers, "Towers")
    M.TowerRefs = req(F.Towers.TowerRefs, "TowerRefs")
    M.Quests = req(F.Quests.QuestConfig, "QuestConfig")
    M.Codes = req(F.Codes.CodesConfig, "CodesConfig")
    M.Daily = req(F.Rewards.DailyRewardConfig, "DailyRewardConfig")
    M.TradeConfig = req(F.Trading.TradeConfig, "TradeConfig")
    M.NF = req(ReplicatedStorage.Packages.NumberFormatter, "NumberFormatter")
    M.Rarities = req(fw.Other.Rarities, "Rarities")
    M.Images = req(fw.Other.Images, "Images")
    local okIcon, icon = pcall(asGame, require, F.Inventory.EntryIcon)
    M.EntryIcon = okIcon and icon or nil
end
local D = M.Data

do
    local raw = CFG.Sell.KeepIncomeAbove
    local value = nil
    if type(raw) == "number" then
        value = raw
    elseif type(raw) == "string" then
        local ok, v = pcall(M.NF.ParseCompact, raw)
        if ok and type(v) == "number" then
            value = v
        end
    end
    if value == nil then
        -- unreadable: keep everything rather than sell what the user meant to keep
        print("[AnimeDice] Sell.KeepIncomeAbove = " .. tostring(raw) .. " is not a number like 1e16 or \"10qd\" - keeping all units")
        value = 1e-9
        S.keepParseError = tostring(raw)
    end
    CFG.Sell.KeepIncomeAbove = value
end

-- ── remotes (raw, never through the game's wrapper) ─────────
local R = {}
do
    local net = ReplicatedStorage:WaitForChild("Network", 30)
    local function remote(key, svc, kind, name)
        local folder = svc and net:WaitForChild(svc, 10) or net
        folder = folder and folder:WaitForChild(kind, 10)
        local r = folder and folder:WaitForChild(name, 10)
        if not r then
            table.insert(S.missing, key)
        end
        R[key] = r
    end
    remote("Roll", "RollService", "RF", "RollDice")
    remote("SetAutoRoll", "RollService", "RE", "SetAutoRoll")
    remote("Collect", "PlotService", "RE", "CollectBalance")
    remote("EquipBest", "PlotService", "RE", "EquipBest")
    remote("LevelSlot", "PlotService", "RE", "LevelUpSlot")
    remote("Sell", "SellService", "RF", "SellInventory")
    remote("Upgrade", nil, "RE", "BuyUpgrade")
    remote("BuyDice", "DiceShopService", "RE", "BuyDice")
    remote("EquipDice", "DiceShopService", "RE", "EquipDice")
    remote("Rebirth", "RebirthService", "RE", "Rebirth")
    remote("AddStat", "RebirthService", "RE", "AddStat")
    remote("PlayTower", "Towers", "RF", "PlayTower")
    remote("FloorTower", "Towers", "RF", "CompleteTowerFloor")
    remote("CancelTower", "Towers", "RF", "CancelTower")
    remote("SetAutoTower", "Towers", "RE", "SetAutoTower")
    remote("BestTeam", "Towers", "RE", "EquipBestTowerTeam")
    remote("QuestClaim", "QuestService", "RE", "Claim")
    remote("QuestBuy", "QuestService", "RE", "Buy")
    remote("Daily", "DailyRewardService", "RE", "Claim")
    remote("Offline", "OfflineEarningsService", "RE", "Claim")
    remote("Code", "CodesService", "RE", "RedeemCode")
    remote("Boost", "BoostService", "RE", "Use")
    remote("Spin", "SpinService", "RE", "Use")
    remote("Gear", "GearService", "RE", "Equip")
    remote("SetLocked", "UnitService", "RE", "SetLocked")
    remote("TReq", "TradeService", "RE", "RequestTrade")
    remote("TResp", "TradeService", "RE", "RespondToRequest")
    remote("TOffer", "TradeService", "RE", "ChangeOffer")
    remote("TAdv", "TradeService", "RE", "AdvanceTrade")
    remote("TCancel", "TradeService", "RE", "CancelTrade")
    remote("TEnable", "TradeService", "RE", "SetTradeRequestsEnabled")
    remote("TEvent", "TradeService", "RE", "TradeEvent")
    if #S.missing > 0 then
        log("missing remotes: " .. table.concat(S.missing, ", ") .. " (game updated?)", "Bad")
    end
end

local function fire(r, ...)
    if r then
        r:FireServer(...)
    end
end

local function invoke(r, ...)
    if not r then
        return false, "missing remote"
    end
    return pcall(r.InvokeServer, r, ...)
end

-- ── helpers ─────────────────────────────────────────────────
local H = {}

function H.fmt(n)
    if type(n) ~= "number" then
        return tostring(n)
    end
    local ok, s = pcall(M.NF.FormatCompact, n)
    if ok and s then
        return s
    end
    return string.format("%.3g", n)
end

function H.buff(name)
    local ok, v = pcall(M.Buff.GetBuff, name)
    if ok and type(v) == "number" then
        return v
    end
    return 0
end

function H.set(list)
    local t = {}
    for _, v in ipairs(list or {}) do
        t[v] = true
    end
    return t
end

function H.count(t)
    local n = 0
    for _ in pairs(t or {}) do
        n = n + 1
    end
    return n
end

-- every unit entry in the inventory: { key, name, attrs, cfg, income }
function H.units()
    local list = {}
    for key, e in pairs(D.Inventory() or {}) do
        local cfg = M.Entry.getEntryConfig(e.name)
        if cfg and cfg.kind == "Unit" then
            local attrs = e.attributes or {}
            local ok, inc = pcall(cfg.income, attrs)
            table.insert(list, { key = key, name = e.name, attrs = attrs, cfg = cfg, income = ok and inc or 0 })
        end
    end
    return list
end

function H.storage()
    local units = H.units()
    local cap = H.buff("Unit Storage")
    return #units, cap, cap - #units, units
end

function H.plotted()
    local t = {}
    for slot, v in pairs(D.Slots() or {}) do
        if type(v) == "table" and v.unitId then
            t[v.unitId] = tonumber(slot)
        end
    end
    return t
end

function H.towerTeamSet()
    local t = {}
    for _, key in pairs(D.TowerTeam() or {}) do
        t[key] = true
    end
    return t
end

function H.slotUnlocked(n)
    return D.Rebirth() >= M.PlotConfig.GetSlotRebirthRequirement(n)
end

function H.tickets()
    local e = (D.Inventory() or {}).Tickets
    return e and e.amount or 0
end

-- units the chain carries: the named ones, or the top N by income when the list is empty
function H.chainUnits(units)
    units = units or H.units()
    local out = {}
    if #CFG.Chain.Units > 0 then
        local want = H.set(CFG.Chain.Units)
        for _, u in ipairs(units) do
            if want[u.name] then
                table.insert(out, u)
            end
        end
    else
        table.sort(units, function(a, b)
            return a.income > b.income
        end)
        for i = 1, math.min(CFG.Chain.TopUnits, #units) do
            table.insert(out, units[i])
        end
    end
    return out
end

-- units that must never be sold
function H.protected(units)
    local keep = H.towerTeamSet()
    if #CFG.Chain.Units > 0 then
        local want = H.set(CFG.Chain.Units)
        for _, u in ipairs(units) do
            if want[u.name] then
                keep[u.key] = true
            end
        end
    elseif S.chainOn then
        for _, u in ipairs(H.chainUnits(table.clone(units))) do
            keep[u.key] = true
        end
    end
    return keep
end

function H.incomePerSec()
    local inv = D.Inventory() or {}
    local total = 0
    for unitKey in pairs(H.plotted()) do
        local e = inv[unitKey]
        local cfg = e and M.Entry.getEntryConfig(e.name)
        if cfg and cfg.kind == "Unit" then
            local ok, inc = pcall(cfg.income, e.attributes or {})
            if ok then
                total = total + inc
            end
        end
    end
    return total * H.buff("Money Multiplier")
end

-- Lua literal of a config table, so queue_on_teleport can rebuild getgenv().AnimeDice
function H.serialize(v)
    local t = type(v)
    if t == "string" then
        return string.format("%q", v)
    elseif t == "number" or t == "boolean" then
        return tostring(v)
    elseif t == "table" then
        local parts = {}
        for k, val in pairs(v) do
            local key
            if type(k) == "number" then
                key = "[" .. k .. "]"
            else
                key = "[" .. string.format("%q", tostring(k)) .. "]"
            end
            table.insert(parts, key .. "=" .. H.serialize(val))
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    return "nil"
end

-- Queued once at startup, so ANY teleport re-runs the script: ours, the game's AFK rejoin
-- (StarterPlayerScripts.AFK) or a kick-to-new-server. Each new run queues itself again.
-- A full relaunch by Masterp/Horst starts a new Roblox process, which only autoexec covers.
function H.queueReexec()
    local q = queueonteleport or queue_on_teleport or (syn and syn.queue_on_teleport)
    if type(q) ~= "function" then
        return false, "executor has no queueonteleport"
    end
    local src = "repeat task.wait() until game:IsLoaded()\n"
        .. "getgenv().AnimeDice=" .. H.serialize(CFG) .. "\n"
        .. "loadstring(game:HttpGet(\"" .. K.MAIN_URL .. "\"))()"
    local ok, err = pcall(q, src)
    if not ok then
        return false, tostring(err)
    end
    return true
end

function H.teleport(jobId)
    S.chain.lastTp = os.time()
    if jobId then
        log("teleport -> server " .. string.sub(jobId, 1, 8))
        local ok, err = pcall(TeleportService.TeleportToPlaceInstance, TeleportService, game.PlaceId, jobId, LP)
        if not ok then
            log("teleport failed: " .. tostring(err), "Bad")
        end
    else
        log("teleport -> new server")
        pcall(TeleportService.Teleport, TeleportService, game.PlaceId, LP)
    end
end

-- public server with at least minFree open slots (Roblox games API)
function H.findServer(minFree)
    local url = "https://games.roblox.com/v1/games/" .. game.PlaceId
        .. "/servers/Public?sortOrder=Desc&limit=100&excludeFullGames=true"
    local ok, body = pcall(game.HttpGet, game, url)
    if not ok then
        log("server list failed: " .. tostring(body), "Warn")
        return nil
    end
    local ok2, data = pcall(HttpService.JSONDecode, HttpService, body)
    if not ok2 or type(data) ~= "table" or type(data.data) ~= "table" then
        return nil
    end
    local best, bestFree = nil, -1
    for _, s in ipairs(data.data) do
        local free = (s.maxPlayers or 0) - (s.playing or 0)
        if s.id ~= game.JobId and free >= minFree and free > bestFree then
            best, bestFree = s.id, free
        end
    end
    return best
end

function H.leave(why)
    S.farm = false
    LP:SetAttribute("AnimeDiceRun", nil)
    if not pcall(function()
        game:Shutdown()
    end) then
        LP:Kick("Anime Dice: " .. why)
    end
end

TeleportService.TeleportInitFailed:Connect(function(plr, result, msg)
    if plr == LP then
        log("teleport rejected: " .. tostring(result) .. " " .. tostring(msg), "Bad")
    end
end)

-- ── static game facts (read once from the live tables) ──────
do
    local i = 0
    while M.Rebirths.Get(i + 1) do
        i = i + 1
    end
    S.maxRebirth = i
    local stop = tonumber(CFG.Rebirth.StopAt) or 0
    S.rebirthTarget = (stop > 0) and math.min(stop, i) or i

    local topPrice = -1
    for name, d in pairs(M.Dice.GetAll()) do
        if d.price and d.price > topPrice then
            topPrice = d.price
            S.topDice = name
        end
    end

    local n = 0
    for name in pairs(M.Upgrades) do
        if name ~= "Start" then
            n = n + 1
        end
    end
    S.upgradeTotal = n
end

function H.upgradesOwned()
    local owned = D.Upgrades() or {}
    local n = 0
    for name in pairs(M.Upgrades) do
        if name ~= "Start" and owned[name] then
            n = n + 1
        end
    end
    return n
end

-- ── shared settings (Goal / Skill Tree / Units / Chain / Potions / Tower tabs) ──
-- Starts from the loader config; once something is changed in the window it is saved to
-- AnimeDice/max_goal.json and every screen on this PC follows that file.
local G = { needDice = false, dice = S.topDice, needRebirth = false, rebirth = S.rebirthTarget,
    needUpgrades = false, giveUp = tonumber(CFG.Chain.UpgradeGiveUpMin) or 0, keepIncome = nil, rev = 0,
    upgrades = nil,          -- list of required upgrade names; nil = every upgrade
    order = nil,             -- chain order override (nil = loader config)
    units = nil,             -- money-maker units handed down the chain (nil = loader config)
    potionOff = {},          -- [boost name] = true → never drink it
    spins = true,            -- use Lucky Spin
    freeSlots = nil,         -- Farm tab: sell when fewer slots than this are free
    tower = nil }            -- { pick, only = {...}, infinity }
do
    local need = H.set(CFG.Chain.MaxedWhen)
    G.needDice = need.Dice == true
    G.needRebirth = need.Rebirth == true
    G.needUpgrades = need.Upgrades == true
end

local GL = { path = "AnimeDice/max_goal.json", seenRev = -1 }

function GL.save()
    G.rev = os.time() + math.random()
    GL.seenRev = G.rev
    if not writefile then
        return
    end
    pcall(function()
        if not isfolder("AnimeDice") then makefolder("AnimeDice") end
        writefile(GL.path, HttpService:JSONEncode(G))
    end)
end

local function strList(t)
    if type(t) ~= "table" then
        return nil
    end
    local out = {}
    for _, v in ipairs(t) do
        if type(v) == "string" and v ~= "" then
            table.insert(out, v)
        end
    end
    return out
end

function GL.load()
    if not (isfile and readfile) or not isfile(GL.path) then
        return false
    end
    local ok, data = pcall(function()
        return HttpService:JSONDecode(readfile(GL.path))
    end)
    if not ok or type(data) ~= "table" or data.rev == GL.seenRev then
        return false
    end
    GL.seenRev = data.rev
    G.rev = data.rev
    G.needDice = data.needDice == true
    if type(data.dice) == "string" and M.Dice.Get(data.dice) then
        G.dice = data.dice
    end
    G.needRebirth = data.needRebirth == true
    G.rebirth = math.clamp(tonumber(data.rebirth) or S.rebirthTarget, 1, S.maxRebirth)
    G.needUpgrades = data.needUpgrades == true
    G.giveUp = math.max(0, tonumber(data.giveUp) or 0)
    if type(data.keepIncome) == "number" then
        G.keepIncome = data.keepIncome
        CFG.Sell.KeepIncomeAbove = data.keepIncome
    end
    G.upgrades = strList(data.upgrades)
    G.order = strList(data.order)
    if G.order then
        CFG.Chain.Order = G.order
    end
    G.units = strList(data.units)
    if G.units then
        CFG.Chain.Units = G.units
    end
    if type(data.freeSlots) == "number" then
        G.freeSlots = math.clamp(math.floor(data.freeSlots), 1, 500)
        CFG.Sell.FreeSlots = G.freeSlots
    end
    G.potionOff = type(data.potionOff) == "table" and data.potionOff or {}
    G.spins = data.spins ~= false
    if type(data.tower) == "table" then
        G.tower = { pick = data.tower.pick == "list" and "list" or "best",
            only = strList(data.tower.only) or {}, infinity = data.tower.infinity ~= false }
        CFG.Tower.Pick = G.tower.pick
        CFG.Tower.Only = G.tower.only
        CFG.Tower.Infinity = G.tower.infinity
    end
    return true
end

-- copy the current runtime values into G (before the first save from the window)
function GL.capture()
    G.order = G.order or table.clone(CFG.Chain.Order)
    G.units = G.units or table.clone(CFG.Chain.Units)
    G.tower = G.tower or { pick = CFG.Tower.Pick, only = table.clone(CFG.Tower.Only), infinity = CFG.Tower.Infinity }
end

-- owns the goal dice, or any dice with at least its luck
function H.hasGoalDice()
    local all = M.Dice.GetAll()
    local goal = all[G.dice]
    if not goal then
        return false
    end
    local owned = D.OwnedDice() or {}
    for name, d in pairs(all) do
        if (owned[name] or name == D.Dice()) and (d.luck or 0) >= (goal.luck or 0) then
            return true
        end
    end
    return false
end

-- required upgrades (Skill Tree tab); nil list = all of them
function H.requiredUpgrades()
    if G.upgrades and #G.upgrades > 0 then
        return G.upgrades
    end
    local all = {}
    for name in pairs(M.Upgrades) do
        if name ~= "Start" then
            table.insert(all, name)
        end
    end
    return all
end

-- ════════════════════════════════════════════════════════════
-- SYSTEMS
-- ════════════════════════════════════════════════════════════
local SYS = {}

-- ── sell ────────────────────────────────────────────────────
function SYS.sell(force)
    if S.pauseSell or S.selling then
        return
    end
    S.selling = true
    local ok, err = pcall(SYS.sellNow, force)
    S.selling = false
    if not ok then
        log("sell error: " .. tostring(err), "Bad")
    end
end

function SYS.sellNow(force)
    local count, cap, free = H.storage()
    local need = math.max(CFG.Sell.FreeSlots, H.buff("Rolls"))
    if not force and free >= need then
        return
    end
    -- plot the best units first so a fresh good roll is never sold
    fire(R.EquipBest)
    task.wait(1.5)
    local units = H.units()
    local plotted = H.plotted()
    local keep = H.protected(units)
    local threshold = tonumber(CFG.Sell.KeepIncomeAbove) or 0
    local list = {}
    local spare = {}
    for _, u in ipairs(units) do
        if not plotted[u.key] and not keep[u.key] and not u.attrs.locked then
            if threshold <= 0 or u.income < threshold then
                table.insert(list, u.key)
            else
                table.insert(spare, u)
            end
        end
    end
    -- KeepIncomeAbove is a preference, not a wall: if keeping them would leave no room to
    -- roll, the weakest of the kept ones go too
    local freeAfter = (cap - #units) + #list
    if freeAfter < need and #spare > 0 then
        table.sort(spare, function(a, b)
            return a.income < b.income
        end)
        for i = 1, math.min(#spare, need - freeAfter) do
            table.insert(list, spare[i].key)
        end
    end
    if #list == 0 then
        S.lastSell = "storage " .. count .. "/" .. cap .. " but nothing sellable"
        return
    end
    local ok, money, n = invoke(R.Sell, list)
    if ok then
        S.lastSell = "sold " .. tostring(n or #list) .. " for $" .. H.fmt(money or 0)
    else
        S.lastSell = "sell error: " .. tostring(money)
        log(S.lastSell, "Bad")
    end
end

-- The trade is refused when either side would end above its Unit Storage after the swap
-- (TradeClass:CollectTransfers). Sell the weakest sellable units until count <= maxCount.
function SYS.makeRoom(maxCount)
    local units = H.units()
    local cap = H.buff("Unit Storage")
    local over = #units - maxCount
    if over <= 0 then
        return true, #units, cap
    end
    local plotted = H.plotted()
    local keep = H.protected(units)
    local cands = {}
    for _, u in ipairs(units) do
        if not plotted[u.key] and not keep[u.key] and not u.attrs.locked then
            table.insert(cands, u)
        end
    end
    table.sort(cands, function(a, b)
        return a.income < b.income
    end)
    local list = {}
    for i = 1, math.min(over, #cands) do
        table.insert(list, cands[i].key)
    end
    if #list > 0 then
        local ok, money, n = invoke(R.Sell, list)
        if ok then
            log("made room for the trade: sold " .. tostring(n or #list) .. " for $" .. H.fmt(money or 0))
        else
            log("make room sell error: " .. tostring(money), "Bad")
        end
        task.wait(1.5)
    end
    local after = #H.units()
    return after <= maxCount, after, cap
end

-- ── roll ────────────────────────────────────────────────────
function SYS.rollLoop()
    fire(R.SetAutoRoll, false) -- the game's own client loop would race ours
    while alive() do
        if S.farm and not S.pauseRoll then
            local count, cap = H.storage()
            local rolls = math.max(1, H.buff("Rolls"))
            -- RollService refuses when UnitStorage + (Rolls - 1) <= unit count
            if count >= cap + rolls - 1 then
                SYS.sell(true)
                task.wait(1)
            else
                local ok, res = invoke(R.Roll)
                if ok and type(res) == "table" then
                    table.insert(S.rollTimes, os.clock())
                    S.rollFails = 0
                    task.wait(math.max(0.05, H.buff("Roll Duration")) + 0.03)
                else
                    if not ok then
                        log("RollDice error: " .. tostring(res), "Bad")
                    end
                    S.rollFails = S.rollFails + 1
                    task.wait(0.25)
                end
            end
        else
            task.wait(0.5)
        end
    end
end

function SYS.rollsPerMin()
    local now = os.clock()
    while S.rollTimes[1] and now - S.rollTimes[1] > 60 do
        table.remove(S.rollTimes, 1)
    end
    return #S.rollTimes
end

-- ── economy: collect, rebirth, stats, upgrades, dice, unit levels ──
function SYS.canSpend(price, money)
    if price > money then
        return false
    end
    local rb = D.Rebirth()
    local nxt = M.Rebirths.GetNext(rb)
    if rb >= S.rebirthTarget or not nxt then
        return true
    end
    return price <= nxt.cost * K.SPEND_SHARE
end

function SYS.collect()
    for slot, v in pairs(D.Slots() or {}) do
        local n = tonumber(slot)
        if n and type(v) == "table" and (v.balance or 0) > 0 and H.slotUnlocked(n) then
            fire(R.Collect, n)
        end
    end
end

function SYS.rebirth()
    local rb = D.Rebirth()
    local nxt = M.Rebirths.GetNext(rb)
    if rb < S.rebirthTarget and nxt and D.Money() >= nxt.cost then
        fire(R.Rebirth)
        log("rebirth -> " .. (rb + 1))
        task.wait(1)
        fire(R.EquipBest) -- new floors may unlock slots
        return true
    end
    return false
end

function SYS.stats()
    local list = {}
    for _, name in ipairs(CFG.Rebirth.Stats) do
        if M.RStats.Get(name) then
            table.insert(list, name)
        end
    end
    if #list == 0 then
        return
    end
    local spentT = table.clone(D.RebirthStats() or {})
    local left = M.RStats.GetRemaining(D.Rebirth(), spentT)
    for _ = 1, math.min(left, 20) do
        local pick, low = nil, math.huge
        for _, name in ipairs(list) do
            local pts = spentT[name] or 0
            if pts < low then
                pick, low = name, pts
            end
        end
        fire(R.AddStat, pick)
        spentT[pick] = low + 1
        task.wait(0.15)
    end
end

function SYS.buyUpgrades(money)
    local owned = D.Upgrades() or {}
    local cands = {}
    for name, u in pairs(M.Upgrades) do
        if name ~= "Start" and not owned[name] then
            local parent = M.Tree.GetParent(name)
            if parent == nil or parent == "Start" or owned[parent] then
                table.insert(cands, { name = name, price = u.price or 0 })
            end
        end
    end
    table.sort(cands, function(a, b)
        return a.price < b.price
    end)
    local bought = 0
    for _, c in ipairs(cands) do
        if bought >= 6 or not SYS.canSpend(c.price, money) then
            break
        end
        fire(R.Upgrade, c.name)
        money = money - c.price
        bought = bought + 1
        S.lastUpgradeBuy = os.time()
        S.lastSpend = "upgrade " .. c.name
        task.wait(0.2)
    end
    return money
end

function SYS.buyDice(money)
    local all = M.Dice.GetAll()
    local ownedT = D.OwnedDice() or {}
    local cur = D.Dice()
    local curLuck = all[cur] and all[cur].luck or 0
    -- equip the best dice we already own (e.g. received or bought earlier)
    local bestOwned, bestOwnedLuck = nil, curLuck
    for name, d in pairs(all) do
        if (ownedT[name] or name == "Basic") and d.luck > bestOwnedLuck then
            bestOwned, bestOwnedLuck = name, d.luck
        end
    end
    if bestOwned then
        fire(R.EquipDice, bestOwned)
        curLuck = bestOwnedLuck
        task.wait(0.6)
    end
    local pick, pickLuck = nil, curLuck
    for name, d in pairs(all) do
        if d.price and not ownedT[name] and d.luck > pickLuck and SYS.canSpend(d.price, money) then
            pick, pickLuck = name, d.luck
        end
    end
    if pick then
        fire(R.BuyDice, pick)
        money = money - all[pick].price
        S.lastSpend = "dice " .. pick
        log("bought dice " .. pick)
        task.wait(0.6)
    end
    return money
end

function SYS.levelUnits(money)
    local inv = D.Inventory() or {}
    local mult = H.buff("Money Multiplier")
    local cands = {}
    for unitKey, slot in pairs(H.plotted()) do
        local e = inv[unitKey]
        local cfg = e and M.Entry.getEntryConfig(e.name)
        if cfg and cfg.kind == "Unit" and H.slotUnlocked(slot) then
            local attrs = e.attributes or {}
            local nextAttrs = table.clone(attrs)
            nextAttrs.level = (attrs.level or 1) + 1
            local ok1, now = pcall(cfg.income, attrs)
            local ok2, after = pcall(cfg.income, nextAttrs)
            local ok3, price = pcall(M.UnitUtil.GetLevelPrice, e.name, attrs)
            if ok1 and ok2 and ok3 and after > now then
                local payback = price / ((after - now) * math.max(mult, 1e-9))
                if payback <= K.LEVEL_PAYBACK then
                    table.insert(cands, { slot = slot, price = price })
                end
            end
        end
    end
    table.sort(cands, function(a, b)
        return a.price < b.price
    end)
    local n = 0
    for _, c in ipairs(cands) do
        if n >= 6 or not SYS.canSpend(c.price, money) then
            break
        end
        fire(R.LevelSlot, c.slot)
        money = money - c.price
        n = n + 1
        S.lastSpend = "level slot " .. c.slot
        task.wait(0.15)
    end
    return money
end

function SYS.economyLoop()
    local tick = 0
    while alive() do
        if S.farm then
            tick = tick + 1
            local ok, err = pcall(function()
                if tick % 3 == 0 then
                    SYS.collect()
                end
                if tick % 20 == 1 then
                    fire(R.EquipBest)
                end
                if not SYS.rebirth() then
                    SYS.stats()
                    local money = D.Money()
                    money = SYS.buyUpgrades(money)
                    money = SYS.buyDice(money)
                    if CFG.Farm.LevelUnits then
                        SYS.levelUnits(money)
                    end
                end
                if tick % 5 == 0 then
                    SYS.sell(false)
                end
            end)
            if not ok then
                log("economy error: " .. tostring(err), "Bad")
                task.wait(3)
            end
        end
        task.wait(1)
    end
end

-- "maxed" = every condition picked in the Goal tab (G) holds
function SYS.maxed()
    local res = { ok = true, parts = {} }
    if G.needRebirth then
        local okR = D.Rebirth() >= G.rebirth
        res.ok = res.ok and okR
        table.insert(res.parts, "Rebirth " .. D.Rebirth() .. "/" .. G.rebirth .. (okR and " ok" or ""))
    end
    if G.needDice then
        local okD = H.hasGoalDice()
        res.ok = res.ok and okD
        table.insert(res.parts, "Dice " .. tostring(G.dice) .. (okD and " ok" or " no"))
    end
    if G.needUpgrades then
        local req = H.requiredUpgrades()
        local ownedT = D.Upgrades() or {}
        local have = 0
        for _, name in ipairs(req) do
            if ownedT[name] then
                have = have + 1
            end
        end
        local okU = have >= #req
        local giveUp = tonumber(G.giveUp) or 0
        if not okU and giveUp > 0 and os.time() - S.lastUpgradeBuy >= giveUp * 60 then
            -- stalled for N minutes: maxed if every remaining required upgrade costs more than we hold
            local money = D.Money()
            local affordable = false
            for _, name in ipairs(req) do
                local u = M.Upgrades[name]
                if u and not ownedT[name] and (u.price or 0) <= money then
                    affordable = true
                    break
                end
            end
            okU = not affordable
        end
        res.ok = res.ok and okU
        table.insert(res.parts, "Upgrades " .. have .. "/" .. #req .. (okU and " ok" or ""))
    end
    res.text = #res.parts > 0 and table.concat(res.parts, " · ") or "no goal set"
    return res
end

-- ── towers ──────────────────────────────────────────────────
function SYS.team()
    local inv = D.Inventory() or {}
    local dm, hm = H.buff("Damage Multiplier"), H.buff("Health Multiplier")
    local team = {}
    for i = 1, M.TowerRefs.MAX_TEAM_SIZE do
        local key = (D.TowerTeam() or {})[i]
        local e = key and inv[key]
        local cfg = e and M.Entry.getEntryConfig(e.name)
        if cfg and cfg.kind == "Unit" then
            local attrs = e.attributes or {}
            table.insert(team, { damage = cfg.damage(attrs) * dm, health = cfg.health(attrs) * hm })
        end
    end
    return team
end

-- replays TowerClass:completeFloor exactly: member HP carries across floors
function SYS.simTower(cfg, team)
    local hp = {}
    for i, m in ipairs(team) do
        hp[i] = m.health
    end
    local member, floor = 1, 1
    local limit = cfg.maxFloors or K.TOWER_CAP
    while floor <= limit do
        local eh = cfg.enemyHealth(floor)
        local ed = cfg.enemyDamage(floor)
        local cleared = false
        local guard = 0
        while member <= #team do
            guard = guard + 1
            if guard > 5000 then
                return floor - 1
            end
            eh = eh - team[member].damage
            if eh <= 0 then
                cleared = true
                break
            end
            hp[member] = hp[member] - ed
            if hp[member] <= 0 then
                member = member + 1
            end
        end
        if not cleared then
            return floor - 1
        end
        floor = floor + 1
    end
    return limit
end

function SYS.pickTower()
    local team = SYS.team()
    if #team == 0 then
        return nil, "no tower team"
    end
    local only = H.set(CFG.Tower.Only)
    local useOnly = #CFG.Tower.Only > 0
    local cands = {}
    for name, cfg in pairs(M.Towers.GetAll()) do
        local allowed
        if useOnly then
            allowed = only[name] == true
        else
            allowed = not cfg.event
        end
        if name == "Infinity Tower" and not CFG.Tower.Infinity then
            allowed = false
        end
        if allowed then
            local ok, floors = pcall(SYS.simTower, cfg, team)
            table.insert(cands, { name = name, cfg = cfg, floors = ok and floors or 0, order = cfg.order or 0 })
        end
    end
    table.sort(cands, function(a, b)
        return a.order < b.order
    end)
    if #cands == 0 then
        return nil, "no tower allowed by config"
    end

    if CFG.Tower.Pick == "list" then
        local list = {}
        if useOnly then
            for _, name in ipairs(CFG.Tower.Only) do
                for _, c in ipairs(cands) do
                    if c.name == name then
                        table.insert(list, c)
                    end
                end
            end
        else
            list = cands
        end
        for _ = 1, #list do
            S.tower.cycle = S.tower.cycle % #list + 1
            local c = list[S.tower.cycle]
            if c.floors >= 1 then
                return c
            end
        end
        return nil, "team clears 0 floors everywhere"
    end

    -- "best": highest finite tower we fully clear → Infinity if it reaches floor 25 → most floors
    local full = nil
    for _, c in ipairs(cands) do
        if c.cfg.maxFloors and c.floors >= c.cfg.maxFloors then
            full = c
        end
    end
    if full then
        return full
    end
    for _, c in ipairs(cands) do
        if c.name == "Infinity Tower" and c.floors >= 25 then
            return c
        end
    end
    local best = nil
    for _, c in ipairs(cands) do
        if c.floors >= 1 and (not best or c.floors >= best.floors) then
            best = c
        end
    end
    if best then
        return best
    end
    return nil, "team clears 0 floors everywhere"
end

function SYS.seqWait(seq)
    local refs = M.TowerRefs
    local total = 0
    for i, a in ipairs(seq) do
        if a.action == refs.Actions.floorStarted then
            local prev = seq[i - 1]
            if i == 1 then
                total = total + (a.floor == 1 and refs.FloorStartedWaitTime.initial or refs.FloorStartedWaitTime.transition)
            elseif prev and prev.action == refs.Actions.memberDefeated then
                total = total + refs.FloorStartedWaitTime.transition
            else
                total = total + refs.FloorStartedWaitTime.repeated
            end
        else
            total = total + (refs.ActionWaitTime[a.action] or 0)
        end
    end
    return total
end

function SYS.runTower(c)
    local ok, started = invoke(R.PlayTower, c.name)
    if not ok or not started then
        S.tower.msg = "PlayTower refused (" .. tostring(started) .. ")"
        return
    end
    S.tower.name = c.name
    S.tower.floor = 1
    S.tower.predicted = c.floors
    S.tower.msg = "running"
    local nils = 0
    while alive() and S.towerOn do
        local ok2, seq = invoke(R.FloorTower)
        if not ok2 then
            log("CompleteTowerFloor error: " .. tostring(seq), "Bad")
            break
        end
        if seq == "destroyed" then
            break
        end
        if type(seq) == "table" and #seq > 0 then
            nils = 0
            local ended = false
            for _, a in ipairs(seq) do
                if a.action == "floorCompleted" then
                    S.tower.floor = (a.floor or 0) + 1
                elseif a.action == "ended" then
                    ended = true
                end
            end
            if ended then
                break
            end
            task.wait(SYS.seqWait(seq) + 0.1)
        else
            nils = nils + 1
            if nils > 60 then
                break
            end
            task.wait(0.25)
        end
    end
    if not S.towerOn then
        invoke(R.CancelTower)
    end
    S.tower.runs = S.tower.runs + 1
    S.tower.msg = "finished " .. c.name .. " at floor " .. (S.tower.floor - 1)
end

function SYS.towerLoop()
    fire(R.SetAutoTower, false)
    while alive() do
        if S.towerOn and S.farm then
            local ok, err = pcall(function()
                fire(R.BestTeam)
                task.wait(1.5)
                local c, why = SYS.pickTower()
                if c then
                    SYS.runTower(c)
                else
                    S.tower.msg = why
                    task.wait(25)
                end
            end)
            if not ok then
                log("tower error: " .. tostring(err), "Bad")
            end
            task.wait(5.5) -- PlayTower has a 5s server debounce
        else
            S.tower.msg = "off"
            task.wait(1)
        end
    end
end

-- ── rewards: quests, ticket shop, daily, offline, codes ─────
function SYS.rewards()
    for period, def in pairs(M.Quests.Periods) do
        local q = D.Quests[period]()
        if q then
            for _, quest in ipairs(def.quests) do
                if not (q.claimed or {})[quest.id] and ((q.progress or {})[quest.id] or 0) >= quest.target then
                    fire(R.QuestClaim, period, quest.id, q.expiresAt)
                    log("quest " .. period .. " " .. quest.id .. " claimed")
                    task.wait(0.3)
                end
            end
        end
    end

    local tickets = H.tickets()
    local gp = D.OwnedGamepasses() or {}
    for _, want in ipairs(CFG.TicketShop) do
        for _, item in ipairs(M.Quests.Shop) do
            if item.name == want and not (item.gamepass and gp[item.name]) and tickets >= item.tickets then
                fire(R.QuestBuy, item.name)
                tickets = tickets - item.tickets
                log("ticket shop: " .. item.name)
                task.wait(0.3)
            end
        end
    end

    local last = D.LastDailyRewardClaim() or 0
    if last == 0 or os.time() - last >= M.Daily.Cooldown then
        fire(R.Daily)
    end
    if (D.PendingOfflineEarnings() or 0) > 0 then
        fire(R.Offline)
    end

    if not S.codesDone then
        S.codesDone = true
        local redeemed = D.RedeemedCodes() or {}
        for code in pairs(M.Codes) do
            if not redeemed[code] then
                fire(R.Code, code)
                log("code " .. code)
                task.wait(0.7)
            end
        end
    end
end

-- ── potions + Lucky Spin ────────────────────────────────────
-- Every potion of every tier and every family (Income, Slayer, Shadow, Pirate, ...) is drunk.
-- BoostService runs only the highest tier of each category; the rest wait with their
-- remaining time frozen (no startedAt) and start the moment the one above expires, so drinking
-- everything at once loses no time, leaves no gap between bottles, and a stronger bottle from a
-- tower drop takes over immediately. Different categories stack (multipliers multiply).
function SYS.items()
    local inv = D.Inventory() or {}
    local spinActive = false
    for _, a in pairs(D.ActiveEntries() or {}) do
        local cfg = M.Entry.getEntryConfig(a.name)
        if cfg and cfg.kind == "Spin" then
            spinActive = true
        end
    end
    local queue = {}
    local spinKey = nil
    for key, e in pairs(inv) do
        local cfg = M.Entry.getEntryConfig(e.name)
        if cfg and (e.amount or 0) > 0 then
            if cfg.kind == "Boost" then
                if not G.potionOff[e.name] then
                    table.insert(queue, { key = key, amount = e.amount, tier = cfg.tier or 0 })
                end
            elseif cfg.kind == "Spin" and e.name ~= "Jackpot Spin" and G.spins then
                spinKey = key
            end
        end
    end
    -- strongest first, so the right bottle is the one running while the rest are queued
    table.sort(queue, function(x, y)
        return x.tier > y.tier
    end)
    local used = 0
    for _, q in ipairs(queue) do
        for _ = 1, q.amount do
            if used >= 40 then
                break -- the rest go on the next tick (15s)
            end
            fire(R.Boost, q.key)
            used = used + 1
            task.wait(0.25)
        end
        log("potion " .. q.key .. " x" .. q.amount)
    end
    if spinKey and not spinActive then
        fire(R.Spin, spinKey)
    end
end

function SYS.slowLoop()
    local tick = 0
    while alive() do
        tick = tick + 1
        if S.farm then
            local ok, err = pcall(function()
                if tick % 30 == 1 then
                    SYS.rewards()
                end
                if CFG.Farm.AutoItems and tick % 15 == 2 then
                    SYS.items()
                end
            end)
            if not ok then
                log("rewards error: " .. tostring(err), "Bad")
            end
        end
        task.wait(1)
    end
end

-- ── anti-AFK ────────────────────────────────────────────────
-- StarterPlayerScripts.AFK teleports to a fresh server after 1080s without UserInputService
-- input (that would break a trade convoy). Its InputBegan handler reschedules the timer, so
-- calling that handler every few minutes keeps us in place.
function SYS.antiAfk()
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
            local ok = pcall(function()
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
            if not ok then
                done = false
            end
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

-- ── graphics ────────────────────────────────────────────────
function SYS.graphics(level)
    if (tonumber(level) or 0) < 1 then
        return
    end
    pcall(function()
        settings().Rendering.QualityLevel = Enum.QualityLevel.Level01
    end)
    pcall(function()
        Lighting.GlobalShadows = false
        Lighting.FogEnd = 1e9
        for _, e in ipairs(Lighting:GetChildren()) do
            if e:IsA("PostEffect") or e:IsA("Atmosphere") then
                e:Destroy()
            end
        end
        local terrain = workspace:FindFirstChildOfClass("Terrain")
        if terrain then
            terrain.WaterWaveSize = 0
            terrain.WaterReflectance = 0
            terrain.Decoration = false
        end
    end)
    local function strip(d)
        if d:IsA("ParticleEmitter") or d:IsA("Trail") or d:IsA("Beam") or d:IsA("Smoke")
            or d:IsA("Fire") or d:IsA("Sparkles") then
            d.Enabled = false
        elseif d:IsA("Decal") or d:IsA("Texture") then
            d.Transparency = 1
        elseif d:IsA("BasePart") then
            d.Material = Enum.Material.SmoothPlastic
            d.Reflectance = 0
            d.CastShadow = false
        elseif d:IsA("PointLight") or d:IsA("SpotLight") or d:IsA("SurfaceLight") then
            d.Enabled = false
        end
    end
    task.spawn(function()
        for i, d in ipairs(workspace:GetDescendants()) do
            pcall(strip, d)
            if i % 3000 == 0 then
                task.wait()
            end
        end
    end)
    workspace.DescendantAdded:Connect(function(d)
        task.defer(pcall, strip, d)
    end)
    if tonumber(level) >= 2 then
        pcall(RunService.Set3dRenderingEnabled, RunService, false)
        if setfpscap then
            pcall(setfpscap, 20)
        end
    end
end

-- ════════════════════════════════════════════════════════════
-- ACCOUNT MANAGER (status text + "done") · Horst / Masterp / Storm / none
--   Horst   _G.Horst_SetDescription(text) · _G.Horst_AccountChangeDone()   ("|" and ";" forbidden)
--   Masterp _G.Masterp_Description(text, payload) · _G.Masterp_Done()      (payload → Google Sheet)
--   Storm   StormAccount.lua over localhost:3030 · acc:SetDescription · acc:MarkFinished
-- The manager's own loader may finish after us, so "Auto" re-detects on every call.
-- ════════════════════════════════════════════════════════════
local MGR = { storm = nil, stormTried = false, lastName = "?", lastDone = nil }

function MGR.fn(name)
    local f = rawget(_G, name)
    if type(f) ~= "function" and getgenv then
        f = rawget(getgenv(), name)
    end
    if type(f) ~= "function" and type(shared) == "table" then
        f = rawget(shared, name)
    end
    if type(f) == "function" then
        return f
    end
    return nil
end

function MGR.kind()
    local want = string.lower(tostring(CFG.Manager or "Auto"))
    if want == "none" then
        return nil
    end
    if want == "horst" or (want == "auto" and MGR.fn("Horst_SetDescription")) then
        return "Horst"
    end
    if want == "masterp" or (want == "auto" and MGR.fn("Masterp_Description")) then
        return "Masterp"
    end
    if want == "storm" then
        return "Storm"
    end
    return nil
end

function MGR.stormAcc()
    if MGR.storm or MGR.stormTried then
        return MGR.storm
    end
    MGR.stormTried = true
    local ok, lib = pcall(function()
        return loadstring(game:HttpGet("https://raw.githubusercontent.com/Androssy/Storm-Launcher/refs/heads/main/StormAccount.lua"))()
    end)
    if ok and type(lib) == "table" and lib.new then
        MGR.storm = lib.new(LP.Name)
    else
        log("Storm: StormAccount.lua failed to load: " .. tostring(lib), "Bad")
    end
    return MGR.storm
end

function MGR.status(text, payload)
    local kind = MGR.kind()
    if tostring(kind) ~= MGR.lastName then
        MGR.lastName = tostring(kind)
        log("account manager: " .. tostring(kind or "none"))
    end
    if kind == "Horst" and MGR.fn("Horst_SetDescription") then
        pcall(MGR.fn("Horst_SetDescription"), (string.gsub(text, "[|;]", ",")))
    elseif kind == "Masterp" and MGR.fn("Masterp_Description") then
        pcall(MGR.fn("Masterp_Description"), text, payload)
    elseif kind == "Storm" then
        local acc = MGR.stormAcc()
        if acc then
            pcall(acc.SetDescription, acc, text)
        end
    end
end

-- returns true when the manager closes Roblox by itself after "done"
function MGR.done(text)
    local kind = MGR.kind()
    if kind == "Horst" then
        if MGR.fn("Horst_SetDescription") then
            pcall(MGR.fn("Horst_SetDescription"), (string.gsub(text, "[|;]", ",")))
        end
        if MGR.fn("Horst_AccountChangeDone") then
            pcall(MGR.fn("Horst_AccountChangeDone"))
        end
    elseif kind == "Masterp" then
        -- Status = Done comes only from Masterp_Done; no Description call here, so nothing
        -- can race or overwrite it (the last farming description stays as it was)
        local f = MGR.fn("Masterp_Done")
        local report
        if f then
            local where = rawget(_G, "Masterp_Done") and "_G"
                or (getgenv and rawget(getgenv(), "Masterp_Done") and "getgenv") or "shared"
            local ok, res = pcall(f)
            report = "Masterp_Done (" .. where .. ") -> " .. (ok and ("ok, returned " .. tostring(res)) or ("ERROR " .. tostring(res)))
        else
            report = "Masterp_Done NOT FOUND (Description works, Done is missing)"
        end
        if report ~= MGR.lastDone then
            MGR.lastDone = report
            log(report, "Warn")
        end
        return true
    elseif kind == "Storm" then
        local acc = MGR.stormAcc()
        if acc then
            pcall(acc.MarkFinished, acc, text)
        end
        return true
    end
    return false
end

-- ════════════════════════════════════════════════════════════
-- CHAIN (build accounts one after another, hand the units down)
-- ════════════════════════════════════════════════════════════
local CH = {}
local T = { active = false, partner = nil, phase = nil, ownOffer = {}, otherOffer = {},
    ownReady = false, otherReady = false, ownAccepted = false, otherAccepted = false,
    ended = nil, incoming = nil, lastOther = {}, justReceived = false,
    updSeq = 0, firedSeq = -1, firedAt = 0 }

if R.TEvent then
    R.TEvent.OnClientEvent:Connect(function(ev, data)
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
            if #T.otherOffer > 0 then
                T.lastOther = T.otherOffer
            end
        elseif ev == "Ended" then
            T.active = false
            T.ended = data.reason or "?"
            T.partner = nil
            if T.ended == "Completed" and #T.lastOther > 0 then
                T.justReceived = true
            end
        end
    end)
end

local function chainFile(name)
    return K.CHAIN_DIR .. "/" .. string.lower(name) .. ".json"
end

function CH.write(extra)
    if not (writefile and isfolder) then
        return
    end
    pcall(function()
        if not isfolder("AnimeDice") then makefolder("AnimeDice") end
        if not isfolder(K.CHAIN_DIR) then makefolder(K.CHAIN_DIR) end
        local count, cap = H.storage()
        local st = {
            name = LP.Name,
            jobId = game.JobId,
            placeId = game.PlaceId,
            public = game.PrivateServerId == "",
            players = #Players:GetPlayers(),
            maxPlayers = Players.MaxPlayers,
            joinedAt = S.joinedAt,
            phase = S.chain.done and "done" or S.chain.phase,
            target = S.chain.target,
            rolls = D.Rolls(),
            age = LP.AccountAge,
            freeStorage = cap - count,
            money = D.Money(),
            income = H.incomePerSec(),
            rebirth = D.Rebirth(),
            units = count,
            cap = cap,
            t = os.time(),
        }
        for k, v in pairs(extra or {}) do
            st[k] = v
        end
        writefile(chainFile(LP.Name), HttpService:JSONEncode(st))
    end)
end

function CH.read(name)
    if not (isfile and readfile) then
        return nil
    end
    local path = chainFile(name)
    if not isfile(path) then
        return nil
    end
    local ok, data = pcall(function()
        return HttpService:JSONDecode(readfile(path))
    end)
    if ok and type(data) == "table" then
        return data
    end
    return nil
end

function CH.fresh(st)
    return st and type(st.t) == "number" and os.time() - st.t <= K.STATE_FRESH
end

function CH.isDone(name)
    if string.lower(name) == string.lower(LP.Name) then
        return S.chain.done
    end
    local st = CH.read(name)
    return st ~= nil and st.phase == "done"
end

-- after DONE: stop farming, report Done to the manager until it closes us
function CH.afterDone(text)
    S.farm = false
    S.towerOn = false
    local wantNone = string.lower(tostring(CFG.Manager)) == "none"
    if wantNone then
        if CFG.Chain.LeaveWhenDone then
            task.wait(5)
            H.leave("chain done")
        end
        return
    end
    -- the manager's client may still be loading: wait for it (up to 90s)
    local t0 = os.clock()
    while alive() and not MGR.kind() and os.clock() - t0 < 90 do
        task.wait(3)
    end
    if not MGR.kind() then
        S.chain.msg = S.chain.msg .. " · manager not found, idling (close this window yourself)"
        log("DONE but no account manager found - not closing Roblox (a rejoin tool would relaunch it)", "Warn")
        return
    end
    MGR.status(string.gsub(text, "^DONE", "Success!"), nil)
    task.wait(2)
    -- keep repeating Done: the manager closes Roblox when it receives it
    while alive() do
        MGR.done(text)
        task.wait(30)
    end
end

function CH.finish(why)
    S.chain.done = true
    S.chain.phase = "done"
    S.chain.msg = "DONE · " .. why
    CH.write()
    log("chain done: " .. why, "Good")
    CH.afterDone("DONE " .. why)
end

-- what the builder hands over: chain units (+ equipped gear)
function CH.offerList()
    local items = {}
    for _, u in ipairs(H.chainUnits()) do
        table.insert(items, { key = u.key, amount = 1, label = u.name, unit = true })
    end
    if CFG.Chain.SendGear then
        local inv = D.Inventory() or {}
        for _, gearName in pairs(D.EquippedGear() or {}) do
            local e = inv[gearName]
            if e and (e.amount or 0) > 0 then
                table.insert(items, { key = gearName, amount = 1, label = gearName })
            end
        end
    end
    while #items > M.TradeConfig.MAX_UNIQUE_ENTRIES do
        table.remove(items)
    end
    return items
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

-- AdvanceTrade toggles "ready" in the Offer phase, so a second press before the server's
-- Updated arrives would un-ready us. Press again only after a newer Updated (or 4s).
function CH.advance()
    if T.updSeq ~= T.firedSeq or os.clock() - T.firedAt > 4 then
        T.firedSeq = T.updSeq
        T.firedAt = os.clock()
        fire(R.TAdv)
    end
end

function CH.sendTo(target)
    local items = CH.offerList()
    if #items == 0 then
        return false, "nothing to send (check Chain.Units spelling)"
    end
    S.pauseRoll = true
    do
        local okRoom, cnt, cap = SYS.makeRoom(H.buff("Unit Storage"))
        if not okRoom then
            S.pauseRoll = false
            return false, "own unit storage " .. cnt .. "/" .. cap .. " and nothing sellable"
        end
    end
    S.pauseSell = true
    local started = false
    for attempt = 1, 4 do
        if T.active then
            fire(R.TCancel)
            task.wait(1)
        end
        T.ended = nil
        S.chain.msg = "requesting trade with " .. target.Name .. " (try " .. attempt .. ")"
        fire(R.TReq, target)
        started = waitFor(function()
            return T.active
        end, 9)
        if started then
            break
        end
        task.wait(7) -- REQUEST_COOLDOWN 6s
    end
    if not started then
        S.pauseRoll, S.pauseSell = false, false
        return false, "target did not accept"
    end
    S.chain.msg = "offering " .. #items .. " items"
    for _, it in ipairs(items) do
        fire(R.TOffer, it.key, it.amount)
        task.wait(0.25)
    end
    waitFor(function()
        for _, it in ipairs(items) do
            if not T.ownOffer[it.key] then
                return false
            end
        end
        return true
    end, 8)
    local deadline = os.clock() + 90
    while T.active and os.clock() < deadline do
        if T.phase == "Offer" and not T.ownReady then
            CH.advance()
            task.wait(0.3)
        elseif T.phase == "Confirm" and not T.ownAccepted then
            CH.advance()
            task.wait(0.3)
        else
            S.chain.msg = "trade phase " .. tostring(T.phase)
            task.wait(0.25)
        end
    end
    if T.active then
        fire(R.TCancel)
        task.wait(1)
    end
    waitFor(function()
        return T.ended ~= nil
    end, 15)
    S.pauseRoll, S.pauseSell = false, false
    local reason = T.ended or "timeout"
    if reason ~= "Completed" then
        return false, reason
    end
    -- confirm on our side: the units must be gone from our inventory
    task.wait(2)
    local inv = D.Inventory() or {}
    for _, it in ipairs(items) do
        if it.unit and inv[it.key] then
            return false, "trade said Completed but " .. it.label .. " is still here"
        end
    end
    return true, reason
end

-- receiver side, runs every chain tick while hosting
function CH.hostTrade(builderName)
    S.pauseSell = T.active
    if T.incoming and os.clock() - T.incoming.at < 6 and not T.active then
        local p = T.incoming.player
        T.incoming = nil
        if p and string.lower(p.Name) == string.lower(builderName) then
            fire(R.TResp, true)
            log("accepted trade from " .. p.Name)
        else
            fire(R.TResp, false)
        end
    end
    if not T.active then
        return
    end
    if not T.partner or string.lower(T.partner.Name) ~= string.lower(builderName) then
        fire(R.TCancel)
        return
    end
    if T.phase == "Offer" and not T.ownReady and T.otherReady and #T.otherOffer > 0 then
        CH.advance()
    elseif T.phase == "Confirm" and not T.ownAccepted then
        CH.advance()
    end
end

-- after receiving: plot the new units and wear the gear we got
function CH.afterReceive()
    task.wait(3)
    fire(R.EquipBest)
    for _, it in ipairs(T.lastOther or {}) do
        local cfg = M.Entry.getEntryConfig(it.name)
        if cfg and cfg.kind == "Gear" and cfg.slot then
            fire(R.Gear, cfg.slot, it.name)
            task.wait(0.4)
        end
    end
    T.lastOther = {}
end

function CH.firstNotDone(fromIndex)
    local order = CFG.Chain.Order
    for i = fromIndex, #order do
        if not CH.isDone(order[i]) then
            return i
        end
    end
    return nil
end

function CH.tick()
    local order = CFG.Chain.Order
    local me = S.chain.myIndex
    S.pauseRoll = false
    CH.write()
    if S.chain.done then
        return
    end
    local bi = CH.firstNotDone(1)
    if not bi then
        S.chain.msg = "whole chain is done"
        return
    end
    local builderName = order[bi]
    S.chain.builderName = builderName
    S.chain.builderIdx = bi

    if bi == me then
        S.chain.role = "builder"
        local mx = SYS.maxed()
        if not mx.ok then
            S.chain.phase = "build"
            S.chain.target = nil
            S.chain.msg = "building · " .. mx.text
            return
        end
        local ni = CH.firstNotDone(me + 1)
        if not ni then
            CH.finish("maxed, last in chain")
            return
        end
        local targetName = order[ni]
        S.chain.phase = "send"
        S.chain.target = targetName
        local st = CH.read(targetName)
        if not CH.fresh(st) then
            S.chain.msg = "maxed · waiting for " .. targetName .. " to come online"
            return
        end
        if LP.AccountAge < M.TradeConfig.MIN_ACCOUNT_AGE or D.Rolls() < M.TradeConfig.MIN_ROLLS then
            S.chain.msg = "this account can't trade yet (age " .. LP.AccountAge .. "d, rolls " .. D.Rolls() .. ")"
            return
        end
        if (st.age or 0) < M.TradeConfig.MIN_ACCOUNT_AGE or (st.rolls or 0) < M.TradeConfig.MIN_ROLLS then
            S.chain.msg = targetName .. " can't trade yet (age " .. tostring(st.age) .. "d, rolls " .. tostring(st.rolls) .. ")"
            return
        end
        if st.jobId ~= game.JobId then
            -- the receiver joins us. We only move when it could never get in:
            -- a private server (no trading there) or one without a free slot.
            local slots = Players.MaxPlayers - #Players:GetPlayers()
            local public = game.PrivateServerId == ""
            if (not public or slots < CFG.Trade.FreeSlots + 1) and CFG.Trade.HostHop
                and os.time() - S.chain.lastHop > K.HOP_COOLDOWN then
                S.chain.lastHop = os.time()
                local id = H.findServer(CFG.Trade.FreeSlots + 2)
                if id then
                    S.chain.msg = "server " .. (public and "full" or "private") .. " · hopping so " .. targetName .. " can join"
                    H.teleport(id)
                    return
                end
            end
            S.chain.msg = "maxed · waiting for " .. targetName .. " to join this server"
                .. (public and (" (" .. slots .. " free)") or " (PRIVATE server - can't trade here)")
            return
        end
        -- stop rolling from here on (rolled units land seconds later) and get under the cap:
        -- after giving our units away we must not be above Unit Storage
        S.pauseRoll = true
        do
            local okRoom, cnt, cap = SYS.makeRoom(H.buff("Unit Storage"))
            if not okRoom then
                S.chain.msg = "own storage " .. cnt .. "/" .. cap .. " - nothing sellable, trade would be refused"
                return
            end
        end
        local myWait = CFG.Trade.WaitAfterJoin - (os.time() - S.joinedAt)
        local theirWait = CFG.Trade.WaitAfterJoin - (os.time() - (st.joinedAt or 0))
        local waitLeft = math.max(myWait, theirWait)
        if waitLeft > 0 then
            S.chain.msg = "same server · trading in " .. waitLeft .. "s"
            return
        end
        local unitCount = 0
        for _, it in ipairs(CH.offerList()) do
            if it.unit then
                unitCount = unitCount + 1
            end
        end
        if (st.freeStorage or 0) < unitCount then
            S.chain.msg = targetName .. " needs " .. unitCount .. " free unit slots (has " .. tostring(st.freeStorage) .. ")"
            return
        end
        local target = nil
        for _, p in ipairs(Players:GetPlayers()) do
            if string.lower(p.Name) == string.lower(targetName) then
                target = p
            end
        end
        if not target then
            S.chain.msg = targetName .. " not in this server yet"
            return
        end
        local ok, reason = CH.sendTo(target)
        if ok then
            log("sent everything to " .. targetName, "Good")
            CH.finish("sent to " .. targetName)
        else
            log("trade failed: " .. tostring(reason), "Bad")
            S.chain.msg = "trade failed: " .. tostring(reason) .. " · retrying"
            if reason == "RecoveryRequired" then
                task.wait(60)
                H.teleport(game.JobId)
            else
                task.wait(10)
            end
        end
        return
    end

    -- not the builder: farm, and host the handover when the builder targets us
    S.chain.role = "waiting (#" .. tostring(me) .. ")"
    local bs = CH.read(builderName)
    if not (CH.fresh(bs) and bs.phase == "send" and type(bs.target) == "string"
        and string.lower(bs.target) == string.lower(LP.Name)) then
        S.chain.phase = "farm"
        S.chain.target = nil
        S.pauseRoll = false
        S.chain.msg = "builder is " .. builderName .. (CH.fresh(bs) and (" (" .. tostring(bs.phase) .. ")") or " (offline)")
        return
    end
    S.chain.phase = "host"
    S.chain.target = builderName
    if D.TradeRequestsEnabled and not D.TradeRequestsEnabled() then
        fire(R.TEnable, true)
    end
    local builderHere = bs.jobId == game.JobId
    S.chain.builderHere = builderHere
    -- stop rolling once the builder is here so storage stays free for the units
    S.pauseRoll = builderHere
    local _, _, free = H.storage()
    if free < math.max(CFG.Sell.FreeSlots, 6) and not T.active then
        SYS.sell(true)
    end
    if builderHere and not T.active then
        local incoming = #CFG.Chain.Units > 0 and (#CFG.Chain.Units + 2) or (CFG.Chain.TopUnits + 2)
        SYS.makeRoom(H.buff("Unit Storage") - incoming)
    end
    if not builderHere then
        local open = (bs.maxPlayers or 0) - (bs.players or 0)
        if bs.public and open >= 1 then
            if os.time() - S.chain.lastTp > 30 then
                S.chain.msg = "joining " .. builderName .. "'s server"
                H.teleport(bs.jobId)
            else
                S.chain.msg = "joining " .. builderName .. "'s server (retry in " .. (30 - (os.time() - S.chain.lastTp)) .. "s)"
            end
        else
            S.chain.msg = "waiting: " .. builderName .. "'s server " .. (bs.public and "is full" or "is private")
        end
        return
    end
    S.chain.msg = "hosting · " .. builderName .. " is here" .. (T.active and (" · trade " .. tostring(T.phase)) or "")
end

function CH.findMe()
    for i, name in ipairs(CFG.Chain.Order) do
        if string.lower(name) == string.lower(LP.Name) then
            return i
        end
    end
    return nil
end

-- once, the first time we are found in the order
function CH.start()
    local prev = CH.read(LP.Name)
    if prev and prev.phase == "done" then
        S.chain.done = true
        S.chain.phase = "done"
        S.chain.msg = "already DONE (delete " .. chainFile(LP.Name) .. " to rebuild)"
        log(S.chain.msg, "Good")
        CH.afterDone("DONE (already)")
        return false
    end
    -- lock named chain units so nothing can sell them by accident
    if #CFG.Chain.Units > 0 then
        local lock = {}
        for _, u in ipairs(H.chainUnits()) do
            if not u.attrs.locked then
                lock[u.key] = true
            end
        end
        if next(lock) then
            fire(R.SetLocked, lock)
        end
    end
    return true
end

function CH.loop()
    local started, warned = false, false
    while alive() do
        if not S.chainOn then
            S.chain.msg = "off"
            task.wait(2)
        else
            local me = CH.findMe()
            S.chain.myIndex = me
            if not me then
                S.chain.msg = LP.Name .. " is not in the chain order - farming only"
                if not warned then
                    warned = true
                    log(S.chain.msg, "Warn")
                end
                task.wait(3)
            elseif not started then
                started = true
                if not CH.start() then
                    return
                end
            else
                if T.justReceived then
                    T.justReceived = false
                    log("received the chain items", "Good")
                    pcall(CH.afterReceive)
                end
                local ok, err = pcall(CH.tick)
                if not ok then
                    log("chain error: " .. tostring(err), "Bad")
                end
                if S.chain.done then
                    return
                end
                if S.chain.phase == "host" then
                    -- fast inner loop while hosting so we answer the request inside its 6s window
                    for _ = 1, 10 do
                        local okH, errH = pcall(CH.hostTrade, S.chain.target or "")
                        if not okH then
                            log("host error: " .. tostring(errH), "Bad")
                        end
                        task.wait(0.3)
                    end
                else
                    task.wait(3)
                end
            end
        end
    end
end

-- ════════════════════════════════════════════════════════════
-- UI · Anime Dice Max hub (same look as the Trade Hub)
--   Status      who is farming now → who is next, queue left, goal bar, chain avatars, stats, log
--   Goal        what "maxed" means: target dice (the game's own dice cards), rebirth, skill tree
--   Skill Tree  the game's upgrade tree; click tiles to choose which ones are required
--   Units       pick the money-maker units handed down the chain
--   Chain       edit the order (paste names) + every account's live status
--   Potions     which potions/tiers get drunk, Lucky Spin
--   Tower       which towers to run, best/list, Infinity
--   Farm        runtime toggles, sell threshold, free slots
-- All writes happen on our own Heartbeat, never inside a game callback.
-- ════════════════════════════════════════════════════════════
local UI = { gui = nil, conns = {}, el = {}, tabs = {}, pages = {}, tab = nil, phase = nil, lastLog = nil,
    visible = true, refreshAt = 0, nodes = {}, diceTiles = {}, chainRows = {}, ids = {}, idQueue = {},
    gridDirty = false }

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

local PHASES = {
    BUILD = { title = "BUILDING", color = Color3.fromRGB(108, 138, 255), sweep = 70, pulse = 0.6 },
    WAIT = { title = "WAITING FOR TRADE", color = Color3.fromRGB(240, 180, 64), sweep = 140, pulse = 1.1 },
    JOIN = { title = "JOINING SERVER", color = Color3.fromRGB(64, 200, 230), sweep = 180, pulse = 1.3 },
    TRADE = { title = "TRADING", color = Color3.fromRGB(190, 110, 255), sweep = 300, pulse = 1.8 },
    SUCCESS = { title = "SUCCESS", color = Color3.fromRGB(74, 210, 128), sweep = 40, pulse = 0.4 },
    QUEUE = { title = "IN QUEUE", color = Color3.fromRGB(130, 136, 156), sweep = 30, pulse = 0.35 },
    FARM = { title = "FARMING", color = Color3.fromRGB(108, 138, 255), sweep = 50, pulse = 0.5 },
    PAUSED = { title = "PAUSED", color = Color3.fromRGB(232, 82, 92), sweep = 20, pulse = 0.25 },
}

local TweenService = game:GetService("TweenService")
local MOTION = {
    Fast = TweenInfo.new(0.12, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
    Base = TweenInfo.new(0.25, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
    Slow = TweenInfo.new(0.45, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
    Spring = TweenInfo.new(0.45, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
}

-- ── kit (shared with the Trade Hub) ───────────────────────
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
    UI.new("UIGradient", { Rotation = 90, Color = ColorSequence.new(Color3.new(1, 1, 1), Color3.fromRGB(196, 200, 216)), Parent = b })
    local edge = UI.stroke(base:Lerp(Color3.new(1, 1, 1), 0.2), 0.55)
    edge.Parent = b
    UI.track(b.MouseEnter:Connect(function()
        UI.tween(b, MOTION.Fast, { BackgroundColor3 = base:Lerp(Color3.new(1, 1, 1), 0.1) })
        UI.tween(edge, MOTION.Fast, { Transparency = 0, Color = base == TH.Panel and TH.Accent or base:Lerp(Color3.new(1, 1, 1), 0.45) })
    end))
    UI.track(b.MouseLeave:Connect(function()
        UI.tween(b, MOTION.Fast, { BackgroundColor3 = base })
        UI.tween(edge, MOTION.Fast, { Transparency = 0.55, Color = base:Lerp(Color3.new(1, 1, 1), 0.2) })
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
    }, { UI.new("UIPadding", { PaddingTop = UDim.new(0, 4), PaddingBottom = UDim.new(0, 8), PaddingLeft = UDim.new(0, 4),
        PaddingRight = UDim.new(0, 8) }) })
    for k, v in pairs(props or {}) do
        sf[k] = v
    end
    return sf
end

function UI.segmented(parent, options, getValue, onPick, props, width)
    local w = width or 70
    local seg = UI.new("Frame", { BackgroundColor3 = TH.Panel, Size = UDim2.fromOffset(#options * w + 6, 36),
        Parent = parent }, { UI.corner(10), UI.stroke() })
    for k, v in pairs(props or {}) do
        seg[k] = v
    end
    local hi = UI.new("Frame", { BackgroundColor3 = TH.Accent, Position = UDim2.fromOffset(3, 3),
        Size = UDim2.fromOffset(w, 30), Parent = seg }, { UI.corner(8) })
    local labels = {}
    for i, opt in ipairs(options) do
        local b = UI.new("TextButton", { AutoButtonColor = false, BackgroundTransparency = 1, Text = opt,
            TextSize = 12, Font = TH.Bold, TextColor3 = TH.Sub, Position = UDim2.fromOffset(3 + (i - 1) * w, 3),
            Size = UDim2.fromOffset(w, 30), ZIndex = 2, Parent = seg })
        labels[opt] = { button = b, index = i }
        UI.track(b.Activated:Connect(function()
            onPick(opt)
        end))
    end
    local api = { frame = seg }
    function api.paint()
        local cur = getValue()
        for opt, l in pairs(labels) do
            local on = opt == cur
            UI.tween(l.button, MOTION.Base, { TextColor3 = on and TH.Text or TH.Sub })
            if on then
                UI.tween(hi, MOTION.Spring, { Position = UDim2.fromOffset(3 + (l.index - 1) * w, 3) })
            end
        end
    end
    api.paint()
    return api
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

function UI.fitScale()
    local vp = workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize or Vector2.new(1920, 1080)
    local byH = (vp.Y * 0.82) / 580
    local byW = (vp.X * 0.9) / 880
    return math.clamp(math.min(byH, byW), 0.55, 1.15)
end


-- ── phase + goal progress ───────────────────────────────────
function UI.phaseKey()
    local ch = S.chain
    if ch.done then
        return "SUCCESS"
    end
    if not S.farm then
        return "PAUSED"
    end
    if not S.chainOn or not ch.myIndex then
        return "FARM"
    end
    if T.active then
        return "TRADE"
    end
    if ch.role == "builder" then
        return ch.phase == "send" and "WAIT" or "BUILD"
    end
    if ch.phase == "host" then
        return ch.builderHere and "WAIT" or "JOIN"
    end
    return "QUEUE"
end

function UI.diceList()
    if UI.dice then
        return UI.dice
    end
    local list = {}
    for name, d in pairs(M.Dice.GetAll()) do
        table.insert(list, { name = name, cfg = d, price = d.price or 0, luck = d.luck or 0 })
    end
    table.sort(list, function(a, b)
        return a.price < b.price
    end)
    UI.dice = list
    return list
end

function UI.diceFrac()
    local list = UI.diceList()
    local best, goal = 1, #list
    local owned = D.OwnedDice() or {}
    for i, d in ipairs(list) do
        if (owned[d.name] or d.name == D.Dice()) and i > best then
            best = i
        end
        if d.name == G.dice then
            goal = i
        end
    end
    return math.clamp((best - 1) / math.max(1, goal - 1), 0, 1)
end

function UI.upgradeFrac()
    local req = H.requiredUpgrades()
    local owned = D.Upgrades() or {}
    local n = 0
    for _, name in ipairs(req) do
        if owned[name] then
            n = n + 1
        end
    end
    return n, #req
end

function UI.goal(key)
    local ch = S.chain
    if key == "SUCCESS" then
        return 1, "sent"
    elseif key == "WAIT" or key == "TRADE" then
        return 1, "maxed"
    elseif key == "QUEUE" or key == "JOIN" then
        local bi = ch.builderIdx or 1
        local me = ch.myIndex or 1
        local ahead = math.max(0, me - bi - 1)
        local frac = me > 1 and math.clamp((bi - 1) / (me - 1), 0, 1) or 1
        return frac, key == "JOIN" and "your turn" or (ahead == 0 and "next up" or (ahead .. " ahead"))
    end
    local sum, n = 0, 0
    if G.needDice then
        sum = sum + (H.hasGoalDice() and 1 or UI.diceFrac())
        n = n + 1
    end
    if G.needRebirth then
        sum = sum + math.clamp(D.Rebirth() / math.max(1, G.rebirth), 0, 1)
        n = n + 1
    end
    if G.needUpgrades then
        local have, total = UI.upgradeFrac()
        sum = sum + have / math.max(1, total)
        n = n + 1
    end
    local f = n > 0 and math.clamp(sum / n, 0, 1) or 1
    return f, math.floor(f * 100 + 0.5) .. "%"
end

function UI.burst(color)
    local orb = UI.el.orb
    if not orb then
        return
    end
    for i = 1, 16 do
        local angle = (i / 16) * math.pi * 2 + math.random() * 0.4
        local dist = 34 + math.random() * 26
        local p = UI.new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5),
            Size = UDim2.fromOffset(5, 5), BackgroundColor3 = (i % 3 == 0) and TH.Text or color, ZIndex = 5, Parent = orb },
            { UI.corner() })
        UI.tween(p, TweenInfo.new(0.7, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), {
            Position = UDim2.new(0.5, math.cos(angle) * dist, 0.5, math.sin(angle) * dist),
            BackgroundTransparency = 1, Size = UDim2.fromOffset(2, 2) })
        task.delay(0.75, function()
            p:Destroy()
        end)
    end
end

function UI.stat(parent, title, order)
    local f = UI.new("Frame", { BackgroundColor3 = TH.Panel, Size = UDim2.new(0.2, -7, 1, 0), LayoutOrder = order, Parent = parent },
        { UI.corner(10), UI.stroke() })
    UI.label(string.upper(title), 10, TH.Dim, TH.Bold, { Position = UDim2.fromOffset(12, 9), Size = UDim2.new(1, -20, 0, 12), Parent = f })
    local v = UI.label("-", 17, TH.Text, TH.Bold, { Position = UDim2.fromOffset(12, 26), Size = UDim2.new(1, -20, 0, 22), Parent = f })
    return { frame = f, value = v, last = nil }
end

-- writes a stat; a rising number flashes green, a falling one red
function UI.setStat(st, text, num, color)
    if st.value.Text ~= text then
        st.value.Text = text
        if num and st.last and num ~= st.last then
            st.value.TextColor3 = num > st.last and TH.Good or TH.Bad
            UI.tween(st.value, MOTION.Slow, { TextColor3 = color or TH.Text })
        else
            st.value.TextColor3 = color or TH.Text
        end
    end
    st.last = num
end

-- account name → user id (cached), then avatar; one lookup at a time
function UI.avatarFor(av, name, color, onId)
    if not name then
        av.set(nil, color)
        return
    end
    local id = UI.ids[string.lower(name)]
    if id then
        av.set(id, color)
        if onId then
            onId(id)
        end
        return
    end
    av.set(nil, color)
    table.insert(UI.idQueue, { name = name, fn = function(uid)
        if uid then
            av.set(uid, color)
        end
        if onId then
            onId(uid)
        end
    end })
    if UI.idWorker then
        return
    end
    UI.idWorker = true
    task.spawn(function()
        while alive() do
            local job = table.remove(UI.idQueue, 1)
            if job then
                local key = string.lower(job.name)
                local uid = UI.ids[key]
                if not uid and not UI.idBad[key] then
                    local ok, res = pcall(Players.GetUserIdFromNameAsync, Players, job.name)
                    if ok and res then
                        uid = res
                        UI.ids[key] = res
                    else
                        UI.idBad[key] = true
                    end
                    task.wait(0.15)
                end
                pcall(job.fn, uid)
            else
                task.wait(0.4)
            end
        end
    end)
end

-- ── Status page ─────────────────────────────────────────────
function UI.buildStatus(page)
    local el = UI.el
    UI.new("UIListLayout", { Padding = UDim.new(0, 10), SortOrder = Enum.SortOrder.LayoutOrder, Parent = page })

    -- hero: who is farming now → who is next
    local hero = UI.new("Frame", { BackgroundColor3 = TH.Panel, Size = UDim2.new(1, 0, 0, 150), LayoutOrder = 1,
        ClipsDescendants = true, Parent = page }, { UI.corner(12), UI.stroke() })
    el.heroGlow = UI.new("UIGradient", { Rotation = 0, Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.82),
        NumberSequenceKeypoint.new(0.45, 1), NumberSequenceKeypoint.new(1, 1) }), Parent = UI.new("Frame", {
        BackgroundColor3 = TH.Accent, Size = UDim2.fromScale(1, 1), BorderSizePixel = 0, Parent = hero }, { UI.corner(12) }) })
    el.heroTint = el.heroGlow.Parent
    el.orb = UI.new("Frame", { Position = UDim2.fromOffset(20, 25), Size = UDim2.fromOffset(100, 100), BackgroundTransparency = 1, Parent = hero })
    el.ring = UI.new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(84, 84),
        BackgroundTransparency = 1, Parent = el.orb }, { UI.corner(), UI.new("UIScale", {}) })
    el.ringStroke = UI.new("UIStroke", { Thickness = 3, Color = TH.Dim, Parent = el.ring })
    el.ringScale = el.ring:FindFirstChildOfClass("UIScale")
    el.heroAv = UI.avatar(el.orb, 80, { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5) })
    el.heroAv.ring.Thickness = 3
    el.heroTag = UI.chip(el.orb, "YOU", TH.Accent, { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 0, 1, -6),
        BackgroundTransparency = 0, TextColor3 = TH.Text, ZIndex = 4 })

    el.title = UI.label("…", 22, TH.Text, TH.Bold, { Position = UDim2.fromOffset(136, 18), Size = UDim2.new(1, -400, 0, 28), Parent = hero })
    el.heroName = UI.label("", 14, TH.Text, TH.Bold, { Position = UDim2.fromOffset(136, 48), Size = UDim2.new(1, -400, 0, 18), Parent = hero })
    el.detail = UI.label("", 12, TH.Sub, TH.Font, { Position = UDim2.fromOffset(136, 70), Size = UDim2.new(1, -400, 0, 16), Parent = hero })
    el.msg = UI.label("", 11, TH.Dim, TH.Font, { Position = UDim2.fromOffset(136, 88), Size = UDim2.new(1, -400, 0, 14), Parent = hero })
    local chips = UI.new("Frame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(136, 110), Size = UDim2.new(1, -400, 0, 22),
        Parent = hero }, { UI.new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6),
        SortOrder = Enum.SortOrder.LayoutOrder }) })
    el.hIncome = UI.chip(chips, "", TH.Good, { LayoutOrder = 1 })
    el.hRebirth = UI.chip(chips, "", TH.Purple, { LayoutOrder = 2 })
    el.hUnits = UI.chip(chips, "", TH.Accent, { LayoutOrder = 3 })

    -- flow arrow + next account
    local nextBox = UI.new("Frame", { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -14, 0, 14), Size = UDim2.fromOffset(250, 122),
        BackgroundColor3 = TH.Bg, Parent = hero }, { UI.corner(10), UI.stroke() })
    el.nextBox = nextBox
    local flow = UI.new("Frame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(8, 46), Size = UDim2.fromOffset(60, 20),
        ClipsDescendants = true, Parent = nextBox })
    el.flow = {}
    for i = 1, 4 do
        el.flow[i] = UI.new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0, 0.5), Size = UDim2.fromOffset(7, 7),
            BackgroundColor3 = TH.Accent, Parent = flow }, { UI.corner() })
    end
    UI.label("›", 22, TH.Sub, TH.Bold, { Position = UDim2.fromOffset(62, 40), Size = UDim2.fromOffset(12, 30), Parent = nextBox })
    el.nextAv = UI.avatar(nextBox, 56, { Position = UDim2.fromOffset(80, 28) })
    UI.label("NEXT UP", 10, TH.Dim, TH.Bold, { Position = UDim2.fromOffset(146, 22), Size = UDim2.fromOffset(96, 12), Parent = nextBox })
    el.nextName = UI.label("-", 13, TH.Text, TH.Bold, { Position = UDim2.fromOffset(146, 38), Size = UDim2.fromOffset(98, 18), Parent = nextBox })
    el.nextInfo = UI.label("", 11, TH.Sub, TH.Font, { Position = UDim2.fromOffset(146, 58), Size = UDim2.fromOffset(98, 14), Parent = nextBox })
    el.queueChip = UI.chip(nextBox, "", TH.Warn, { AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -10) })

    -- goal bar
    local bar = UI.new("Frame", { BackgroundColor3 = TH.Panel, Size = UDim2.new(1, 0, 0, 52), LayoutOrder = 2, Parent = page },
        { UI.corner(10), UI.stroke() })
    el.barLabel = UI.label("GOAL", 10, TH.Dim, TH.Bold, { Position = UDim2.fromOffset(14, 9), Size = UDim2.new(0.7, 0, 0, 12), Parent = bar })
    el.barValue = UI.label("0%", 11, TH.Text, TH.Bold, { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -14, 0, 8),
        Size = UDim2.new(0.3, 0, 0, 14), TextXAlignment = Enum.TextXAlignment.Right, Parent = bar })
    local track = UI.new("Frame", { BackgroundColor3 = TH.Elevated, Position = UDim2.fromOffset(14, 30), Size = UDim2.new(1, -28, 0, 8),
        ClipsDescendants = true, Parent = bar }, { UI.corner() })
    el.fill = UI.new("Frame", { Size = UDim2.fromScale(0.02, 1), BackgroundColor3 = TH.Accent, Parent = track }, { UI.corner() })
    el.shine = UI.new("UIGradient", { Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0),
        NumberSequenceKeypoint.new(0.45, 0), NumberSequenceKeypoint.new(0.5, 0.65), NumberSequenceKeypoint.new(0.55, 0),
        NumberSequenceKeypoint.new(1, 0) }), Offset = Vector2.new(-1, 0), Parent = el.fill })
    UI.tween(el.shine, TweenInfo.new(1.6, Enum.EasingStyle.Linear, Enum.EasingDirection.InOut, -1), { Offset = Vector2.new(1, 0) })

    -- chain strip: 7 avatars around the builder
    local chainRow = UI.new("Frame", { BackgroundColor3 = TH.Panel, Size = UDim2.new(1, 0, 0, 74), LayoutOrder = 3, Parent = page },
        { UI.corner(10), UI.stroke() })
    el.chainRow = chainRow
    el.line = UI.new("Frame", { BackgroundColor3 = TH.Stroke, BorderSizePixel = 0, Position = UDim2.new(1 / 14, 0, 0, 27),
        Size = UDim2.new(12 / 14, 0, 0, 2), Parent = chainRow })
    el.lineDone = UI.new("Frame", { BackgroundColor3 = TH.Good, BorderSizePixel = 0, Size = UDim2.fromScale(0, 1), Parent = el.line })
    for i = 1, 7 do
        local x = (2 * i - 1) / 14
        local holder = UI.new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(x, 0, 0, 28), Size = UDim2.fromOffset(34, 34),
            BackgroundTransparency = 1, Parent = chainRow }, { UI.new("UIScale", {}) })
        local av = UI.avatar(holder, 34, {})
        local check = UI.new("TextLabel", { AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, 4, 1, 4), Size = UDim2.fromOffset(15, 15),
            BackgroundColor3 = TH.Good, Text = "✓", TextSize = 10, Font = TH.Bold, TextColor3 = TH.Bg, ZIndex = 3, Visible = false,
            Parent = holder }, { UI.corner() })
        local name = UI.label("", 10, TH.Dim, TH.Font, { AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(x, 0, 0, 49),
            Size = UDim2.fromOffset(86, 14), TextXAlignment = Enum.TextXAlignment.Center, Parent = chainRow })
        UI.nodes[i] = { holder = holder, av = av, check = check, scale = holder:FindFirstChildOfClass("UIScale"), name = name, who = nil }
    end

    -- this screen's numbers
    local stats = UI.new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 58), LayoutOrder = 4, Parent = page },
        { UI.new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 8),
            SortOrder = Enum.SortOrder.LayoutOrder }) })
    el.sMoney = UI.stat(stats, "Money", 1)
    el.sIncome = UI.stat(stats, "Income / s", 2)
    el.sRebirth = UI.stat(stats, "Rebirth", 3)
    el.sUnits = UI.stat(stats, "Units", 4)
    el.sRolls = UI.stat(stats, "Rolls / min", 5)

    local info = UI.new("Frame", { BackgroundColor3 = TH.Panel, Size = UDim2.new(1, 0, 1, -384), LayoutOrder = 5, Parent = page },
        { UI.corner(10), UI.stroke(), UI.pad(10) })
    el.tower = UI.label("", 11, TH.Sub, TH.Bold, { Size = UDim2.new(1, 0, 0, 16), Parent = info })
    el.logLines = {}
    for i = 1, 4 do
        el.logLines[i] = UI.label("", 11, TH.Sub, TH.Mono, { Position = UDim2.fromOffset(0, 4 + i * 16), Size = UDim2.new(1, 0, 0, 15), Parent = info })
    end
end

-- chain counts read from the chain files (every 3s, not every frame)
function UI.chainCounts()
    local t = os.clock()
    if UI.cc and t - UI.cc.at < 3 then
        return UI.cc
    end
    local order = CFG.Chain.Order
    local cc = { at = t, done = {}, nDone = 0, bi = nil, nextIdx = nil, left = 0, builder = nil }
    for i, name in ipairs(order) do
        if CH.isDone(name) then
            cc.done[i] = true
            cc.nDone = cc.nDone + 1
        elseif not cc.bi then
            cc.bi = i
        else
            -- still waiting behind the builder
            cc.left = cc.left + 1
            if not cc.nextIdx then
                cc.nextIdx = i
            end
        end
    end
    if cc.bi then
        cc.builder = CH.read(order[cc.bi])
    end
    UI.cc = cc
    return cc
end

-- hero numbers for the farming account: our own data, or the builder's chain file
function UI.heroNumbers(name)
    if string.lower(name) == string.lower(LP.Name) then
        local count, cap = H.storage()
        return { income = H.incomePerSec(), rebirth = D.Rebirth(), units = count, cap = cap, fresh = true }
    end
    local st = UI.cc and UI.cc.builder
    if st and type(st.income) == "number" then
        return { income = st.income, rebirth = st.rebirth, units = st.units, cap = st.cap, fresh = CH.fresh(st) }
    end
    return nil
end

function UI.refreshHero()
    local el = UI.el
    local chainOn = S.chainOn and #CFG.Chain.Order > 0
    local cc = chainOn and UI.chainCounts() or nil
    local order = CFG.Chain.Order
    local who = LP.Name
    if cc and cc.bi then
        who = order[cc.bi]
    end
    local ph = PHASES[UI.phase or "FARM"] or PHASES.FARM
    if el.heroWho ~= who then
        el.heroWho = who
        UI.avatarFor(el.heroAv, who, ph.color)
        el.heroTag.Text = string.lower(who) == string.lower(LP.Name) and "YOU" or ("#" .. tostring(cc and cc.bi or "?"))
    end
    el.heroAv.ring.Color = ph.color
    el.heroName.Text = (string.lower(who) == string.lower(LP.Name) and (who .. "  (this screen)") or (who .. "  is farming"))
        .. ((cc and cc.bi) and ("  ·  #" .. cc.bi .. " of " .. #order) or "")
    local nums = UI.heroNumbers(who)
    el.hIncome.Visible = nums ~= nil
    el.hRebirth.Visible = nums ~= nil
    el.hUnits.Visible = nums ~= nil
    if nums then
        el.hIncome.Text = "$" .. H.fmt(nums.income or 0) .. "/s"
        el.hRebirth.Text = "Rebirth " .. tostring(nums.rebirth or "?") .. (G.needRebirth and (" / " .. G.rebirth) or "")
        el.hUnits.Text = "Units " .. tostring(nums.units or "?") .. "/" .. tostring(nums.cap or "?")
    end

    -- next account
    local nextName = cc and cc.nextIdx and order[cc.nextIdx] or nil
    if not chainOn then
        el.nextName.Text = "Chain off"
        el.nextInfo.Text = "farming only"
        el.queueChip.Text = "solo"
    elseif not cc.bi then
        el.nextName.Text = "Finished"
        el.nextInfo.Text = "whole chain DONE"
        el.queueChip.Text = "✓ " .. cc.nDone .. " / " .. #order .. " done"
        el.queueChip.TextColor3 = TH.Good
        el.queueChip.BackgroundColor3 = TH.Good
    else
        el.nextName.Text = nextName or "last one"
        local me = S.chain.myIndex
        el.nextInfo.Text = (me and cc.nextIdx == me) and "that's you!" or (nextName and ("#" .. cc.nextIdx) or "no one after")
        el.queueChip.Text = cc.left .. " left in queue · " .. cc.nDone .. " done"
        el.queueChip.TextColor3 = TH.Warn
        el.queueChip.BackgroundColor3 = TH.Warn
    end
    if el.nextWho ~= (nextName or "") then
        el.nextWho = nextName or ""
        UI.avatarFor(el.nextAv, nextName, TH.Stroke)
    end
    for _, d in ipairs(el.flow) do
        d.Visible = chainOn and nextName ~= nil
        d.BackgroundColor3 = ph.color
    end

    -- chain strip
    el.chainRow.Visible = chainOn
    if not chainOn then
        return
    end
    local bi = cc.bi or #order
    local first = math.clamp(bi - 3, 1, math.max(1, #order - 6))
    UI.activeNode = nil
    local lastDone = 0
    for i = 1, 7 do
        local idx = first + i - 1
        local n = UI.nodes[i]
        local name = order[idx]
        n.holder.Visible = name ~= nil
        n.name.Visible = name ~= nil
        if name then
            if n.who ~= name then
                n.who = name
                UI.avatarFor(n.av, name, TH.Stroke)
            end
            local isMe = string.lower(name) == string.lower(LP.Name)
            n.name.Text = isMe and "you" or string.sub(name, 1, 11)
            n.name.TextColor3 = (idx == bi or isMe) and TH.Text or TH.Dim
            local done = cc.done[idx] == true
            n.check.Visible = done
            if done then
                lastDone = i
            end
            n.av.ring.Color = idx == bi and ph.color or (done and TH.Good or (isMe and TH.Text or TH.Stroke))
            n.av.holder.BackgroundTransparency = (done or idx == bi) and 0 or 0.4
            if idx == bi then
                UI.activeNode = n
            else
                n.scale.Scale = 1
            end
        end
    end
    local activeAt = bi - first + 1
    el.lineDone.Size = UDim2.fromScale(math.clamp((math.max(lastDone, activeAt) - 1) / 6, 0, 1), 1)
end

function UI.setPhase(key)
    local ph = PHASES[key] or PHASES.FARM
    local el = UI.el
    UI.phase = key
    el.title.Text = ph.title
    el.title.TextTransparency = 1
    el.title.Position = UDim2.fromOffset(136, 26)
    UI.tween(el.title, MOTION.Slow, { TextTransparency = 0, Position = UDim2.fromOffset(136, 18) })
    UI.tween(el.title, MOTION.Base, { TextColor3 = ph.color:Lerp(TH.Text, 0.35) })
    UI.tween(el.fill, MOTION.Base, { BackgroundColor3 = ph.color })
    UI.tween(el.sideDot, MOTION.Base, { BackgroundColor3 = ph.color })
    UI.tween(el.heroTint, MOTION.Slow, { BackgroundColor3 = ph.color })
    el.ringStroke.Color = ph.color
    el.heroAv.ring.Color = ph.color
    el.sidePhase.Text = ph.title
    el.sidePhase.TextColor3 = ph.color
    el.sweep.Color = ColorSequence.new({ ColorSequenceKeypoint.new(0, TH.Stroke), ColorSequenceKeypoint.new(0.5, ph.color),
        ColorSequenceKeypoint.new(1, TH.Stroke) })
    if key == "SUCCESS" then
        UI.burst(ph.color)
        UI.toast("Success! units handed over", "Good")
    end
end

function UI.refreshStatus()
    local el = UI.el
    local key = UI.phaseKey()
    if key ~= UI.phase then
        UI.setPhase(key)
    end
    local ch = S.chain
    local order = CFG.Chain.Order
    el.badge.Text = (S.chainOn and ch.myIndex) and ("#" .. ch.myIndex .. " / " .. #order) or LP.Name
    el.detail.Text = UI.activity()
    el.msg.Text = tostring(ch.msg or "")
    local frac, right = UI.goal(key)
    el.barLabel.Text = (key == "QUEUE" or key == "JOIN") and "CHAIN TURN" or "GOAL"
    el.barValue.Text = right
    if UI.lastFrac ~= frac then
        UI.lastFrac = frac
        UI.tween(el.fill, MOTION.Slow, { Size = UDim2.fromScale(math.max(frac, 0.02), 1) })
    end
    UI.refreshHero()
    local count, cap = H.storage()
    local money, income, reb = D.Money(), H.incomePerSec(), D.Rebirth()
    UI.setStat(el.sMoney, "$" .. H.fmt(money), money)
    UI.setStat(el.sIncome, "$" .. H.fmt(income), income, TH.Good)
    UI.setStat(el.sRebirth, reb .. " / " .. (G.needRebirth and G.rebirth or S.maxRebirth), reb, TH.Purple)
    UI.setStat(el.sUnits, count .. "/" .. cap, nil, (cap - count < CFG.Sell.FreeSlots) and TH.Warn or TH.Text)
    UI.setStat(el.sRolls, tostring(SYS.rollsPerMin()), nil)
    local tw = S.tower
    el.tower.Text = S.towerOn and string.format("TOWER   %s · floor %d (sim %d) · runs %d", tw.name, tw.floor, tw.predicted, tw.runs)
        or "TOWER   off"
    for i = 1, 4 do
        local l = S.logLines[i]
        el.logLines[i].Text = l and ("› " .. l.text) or ""
        el.logLines[i].TextColor3 = l and (l.kind == "Bad" and TH.Bad or (l.kind == "Good" and TH.Good or TH.Sub)) or TH.Sub
    end
end


-- a template from the game's own PlayerGui (dice shop card, skill tree tile); a Clone has the
-- look but none of the game's scripts/connections
function UI.gameTemplate(kind)
    local ok, inst = pcall(function()
        local root = LP.PlayerGui.Root
        if kind == "dice" then
            return root.Menus.DiceShop.Content.ScrollingFrame.Template
        elseif kind == "upgrade" then
            return root.Upgrades.Screen.Template
        end
    end)
    return ok and inst or nil
end

-- ── icons for units (the game's EntryIcon, cloned on a worker thread) ──
local ICON = { queue = {}, done = {} }

function ICON.request(name, holder)
    table.insert(ICON.queue, { name = name, holder = holder })
end

function ICON.workerLoop()
    while alive() do
        local job = table.remove(ICON.queue, 1)
        if job then
            local ok, icon = pcall(function()
                return asGame(function()
                    local _, inst = M.EntryIcon.new({ name = job.name, tooltip = false })
                    local copy = inst:Clone()
                    inst:Destroy()
                    if not copy then
                        error("icon is not cloneable")
                    end
                    for _, vf in ipairs(copy:GetDescendants()) do
                        if vf:IsA("ViewportFrame") then
                            local cam = vf:FindFirstChildOfClass("Camera")
                            if cam and vf.CurrentCamera ~= cam then
                                vf.CurrentCamera = cam
                            end
                        end
                    end
                    return copy
                end)
            end)
            table.insert(ICON.done, { job = job, icon = ok and icon or nil })
        else
            task.wait(0.05)
        end
    end
end

function UI.deliverIcons()
    while #ICON.done > 0 do
        local d = table.remove(ICON.done, 1)
        local holder = d.job.holder
        if holder and holder.Parent and d.icon then
            pcall(function()
                for _, desc in ipairs(d.icon:GetDescendants()) do
                    if desc:IsA("TextLabel") or desc:IsA("TextButton") then
                        desc.Visible = false
                    end
                end
                d.icon.AnchorPoint = Vector2.new(0.5, 0.5)
                d.icon.Position = UDim2.fromScale(0.5, 0.5)
                d.icon.Size = UDim2.fromScale(1, 1)
                d.icon.Parent = holder
                local ph = holder:FindFirstChild("Placeholder")
                if ph then
                    ph:Destroy()
                end
            end)
        end
    end
end

-- ── window ──────────────────────────────────────────────────
function UI.build()
    local okH, h = pcall(function()
        return gethui and gethui()
    end)
    local parent = (okH and h) or game:GetService("CoreGui")
    local old = parent:FindFirstChild("AnimeDiceMaxHub")
    if old then
        old:Destroy()
    end
    local gui = UI.new("ScreenGui", { Name = "AnimeDiceMaxHub", ResetOnSpawn = false, IgnoreGuiInset = true,
        ZIndexBehavior = Enum.ZIndexBehavior.Sibling, DisplayOrder = 999 })
    gui.Parent = parent
    UI.gui = gui
    UI.idBad = {}
    local el = UI.el
    el.win = UI.new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5),
        Size = UDim2.fromOffset(880, 580), BackgroundColor3 = TH.Bg, Parent = gui },
        { UI.corner(14), UI.new("UIScale", { Scale = 0.9 }) })
    el.scale = el.win:FindFirstChildOfClass("UIScale")
    el.border = UI.new("UIStroke", { Color = Color3.new(1, 1, 1), Thickness = 1.5, Parent = el.win })
    el.sweep = UI.new("UIGradient", { Parent = el.border })

    local header = UI.new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 46), Parent = el.win })
    UI.label("ANIME DICE", 13, TH.Text, TH.Bold, { Position = UDim2.fromOffset(18, 0), Size = UDim2.fromOffset(90, 46), Parent = header })
    UI.label("· By Aimika", 13, TH.Dim, TH.Bold, { Position = UDim2.fromOffset(104, 0), Size = UDim2.fromOffset(90, 46), Parent = header })
    UI.chip(header, "MAX", TH.Accent, { AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 196, 0.5, 0) })
    el.badge = UI.chip(header, "-", TH.Sub, { AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -76, 0.5, 0) })
    local function topButton(text, x, hover, fn)
        local b = UI.new("TextButton", { AutoButtonColor = false, AnchorPoint = Vector2.new(1, 0.5),
            Position = UDim2.new(1, x, 0.5, 0), Size = UDim2.fromOffset(26, 26), BackgroundColor3 = TH.Elevated,
            BackgroundTransparency = 1, Text = text, TextSize = 16, Font = TH.Bold, TextColor3 = TH.Dim, Parent = header },
            { UI.corner(7) })
        UI.track(b.MouseEnter:Connect(function()
            UI.tween(b, MOTION.Fast, { BackgroundTransparency = 0, TextColor3 = hover })
        end))
        UI.track(b.MouseLeave:Connect(function()
            UI.tween(b, MOTION.Fast, { BackgroundTransparency = 1, TextColor3 = TH.Dim })
        end))
        UI.track(b.Activated:Connect(fn))
    end
    topButton("×", -12, TH.Bad, function()
        if LP:GetAttribute("AnimeDiceRun") == TOKEN then
            LP:SetAttribute("AnimeDiceRun", nil)
            log("stopped (window closed)")
        end
        UI.destroy()
    end)
    topButton("–", -42, TH.Text, function()
        UI.visible = false
        UI.gui.Enabled = false
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

    local sideBg = UI.new("Frame", { BackgroundColor3 = TH.Panel, BorderSizePixel = 0, Position = UDim2.fromOffset(0, 47),
        Size = UDim2.new(0, 150, 1, -47), Parent = el.win }, { UI.corner(14) })
    UI.new("Frame", { BackgroundColor3 = TH.Panel, BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, 16), Parent = sideBg })
    UI.new("Frame", { BackgroundColor3 = TH.Panel, BorderSizePixel = 0, AnchorPoint = Vector2.new(1, 0),
        Position = UDim2.fromScale(1, 0), Size = UDim2.new(0, 16, 1, 0), Parent = sideBg })
    el.sidebar = UI.new("Frame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(0, 47),
        Size = UDim2.new(0, 150, 1, -47), Parent = el.win },
        { UI.new("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }),
          UI.new("UIPadding", { PaddingTop = UDim.new(0, 10), PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10) }) })
    el.indicator = UI.new("Frame", { BackgroundColor3 = TH.Accent, BorderSizePixel = 0, Size = UDim2.fromOffset(3, 18),
        Position = UDim2.fromOffset(4, 66), ZIndex = 3, Parent = el.win }, { UI.corner(2) })
    el.pages = UI.new("Frame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(150, 47),
        Size = UDim2.new(1, -150, 1, -47), ClipsDescendants = true, Parent = el.win })
    UI.new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 130), LayoutOrder = 50, Parent = el.sidebar })
    local side = UI.new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 60), LayoutOrder = 99, Parent = el.sidebar })
    el.sideDot = UI.new("Frame", { Position = UDim2.fromOffset(4, 24), Size = UDim2.fromOffset(10, 10),
        BackgroundColor3 = TH.Dim, Parent = side }, { UI.corner() })
    el.sidePhase = UI.label("…", 12, TH.Text, TH.Bold, { Position = UDim2.fromOffset(20, 16), Size = UDim2.new(1, -20, 0, 16), Parent = side })
    UI.label(LP.Name, 10, TH.Dim, TH.Font, { Position = UDim2.fromOffset(20, 32), Size = UDim2.new(1, -20, 0, 14), Parent = side })

    UI.buildStatus(UI.page("Status", 1))
    UI.buildGoal(UI.page("Goal", 2))
    UI.buildTree(UI.page("Skill Tree", 3))
    UI.buildUnits(UI.page("Units", 4))
    UI.buildChain(UI.page("Chain", 5))
    UI.buildPotions(UI.page("Potions", 6))
    UI.buildTower(UI.page("Tower", 7))
    UI.buildFarm(UI.page("Farm", 8))

    el.win.BackgroundTransparency = 1
    UI.tween(el.win, MOTION.Slow, { BackgroundTransparency = 0 })
    UI.tween(el.scale, MOTION.Spring, { Scale = UI.fitScale() })
    UI.track(workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
        UI.tween(el.scale, MOTION.Base, { Scale = UI.fitScale() })
    end))
    task.defer(function()
        UI.select("Status")
    end)
    UI.track(UserInputService.InputBegan:Connect(function(input, gp)
        if not gp and input.KeyCode == Enum.KeyCode.RightControl then
            UI.visible = not UI.visible
            UI.gui.Enabled = UI.visible
        end
    end))
    UI.track(RunService.Heartbeat:Connect(UI.frame))
end

-- one dice card: the game's own dice-shop card (cloned), or a plain tile if it isn't there
-- ── Goal page ───────────────────────────────────────────────
local LIGHT_RAY = "rbxassetid://18930364478"   -- DiceShop card light ray (dump 2026-11-02)

function UI.save()
    GL.capture()
    GL.save()
end

-- one of the three goal cards at the top of the Goal tab
function UI.goalCard(parent, order, title, getOn, onToggle)
    local card = UI.new("TextButton", { AutoButtonColor = false, Text = "", BackgroundColor3 = TH.Panel,
        Size = UDim2.new(1 / 3, -6, 1, 0), LayoutOrder = order, Parent = parent }, { UI.corner(12) })
    local st = UI.stroke(TH.Stroke)
    st.Parent = card
    UI.label(string.upper(title), 10, TH.Dim, TH.Bold, { Position = UDim2.fromOffset(14, 12), Size = UDim2.new(1, -70, 0, 12), Parent = card })
    local track = UI.new("Frame", { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -12, 0, 9), Size = UDim2.fromOffset(34, 18),
        BackgroundColor3 = TH.Elevated, Parent = card }, { UI.corner() })
    local knob = UI.new("Frame", { AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 3, 0.5, 0), Size = UDim2.fromOffset(12, 12),
        BackgroundColor3 = TH.Sub, Parent = track }, { UI.corner() })
    local value = UI.label("", 18, TH.Text, TH.Bold, { Position = UDim2.fromOffset(14, 32), Size = UDim2.new(1, -28, 0, 24), Parent = card })
    local sub = UI.label("", 11, TH.Sub, TH.Font, { Position = UDim2.fromOffset(14, 58), Size = UDim2.new(1, -28, 0, 14), Parent = card })
    local api = { card = card, value = value, sub = sub }
    function api.paint()
        local on = getOn()
        UI.tween(track, MOTION.Base, { BackgroundColor3 = on and TH.Accent or TH.Elevated })
        UI.tween(knob, MOTION.Spring, { Position = on and UDim2.new(1, -15, 0.5, 0) or UDim2.new(0, 3, 0.5, 0),
            BackgroundColor3 = on and TH.Text or TH.Sub })
        UI.tween(st, MOTION.Base, { Color = on and TH.Accent or TH.Stroke })
        UI.tween(value, MOTION.Base, { TextColor3 = on and TH.Text or TH.Dim })
    end
    UI.track(card.Activated:Connect(function()
        onToggle(not getOn())
        api.paint()
    end))
    return api
end

function UI.smallButton(parent, text, props, fn)
    local b = UI.new("TextButton", { AutoButtonColor = false, Size = UDim2.fromOffset(28, 28), BackgroundColor3 = TH.Elevated,
        Text = text, TextSize = 14, Font = TH.Bold, TextColor3 = TH.Sub, ZIndex = 3, Parent = parent }, { UI.corner(8),
        UI.new("UIGradient", { Rotation = 90, Color = ColorSequence.new(Color3.new(1, 1, 1), Color3.fromRGB(190, 194, 210)) }) })
    local edge = UI.stroke(TH.Stroke)
    edge.Parent = b
    for k, v in pairs(props or {}) do
        b[k] = v
    end
    UI.press(b)
    UI.track(b.MouseEnter:Connect(function()
        UI.tween(b, MOTION.Fast, { BackgroundColor3 = TH.Accent, TextColor3 = TH.Text })
        UI.tween(edge, MOTION.Fast, { Color = TH.Accent:Lerp(Color3.new(1, 1, 1), 0.4) })
    end))
    UI.track(b.MouseLeave:Connect(function()
        UI.tween(b, MOTION.Fast, { BackgroundColor3 = TH.Elevated, TextColor3 = TH.Sub })
        UI.tween(edge, MOTION.Fast, { Color = TH.Stroke })
    end))
    UI.track(b.Activated:Connect(fn))
    return b
end

function UI.buildGoal(page)
    local el = UI.el
    el.goalSummary = UI.label("", 13, TH.Text, TH.Bold, { Size = UDim2.new(1, 0, 0, 18), Parent = page })
    local cards = UI.new("Frame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(0, 26), Size = UDim2.new(1, 0, 0, 112), Parent = page },
        { UI.new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 9), SortOrder = Enum.SortOrder.LayoutOrder }) })

    -- rebirth
    el.gReb = UI.goalCard(cards, 1, "Rebirth", function()
        return G.needRebirth
    end, function(v)
        G.needRebirth = v
        UI.save()
        UI.paintGoal()
    end)
    local function rebStep(text, x, delta)
        UI.smallButton(el.gReb.card, text, { AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, x, 1, -10),
            Size = UDim2.fromOffset(text == "MAX" and 48 or 28, 28), TextSize = text == "MAX" and 11 or 15 }, function()
            G.rebirth = math.clamp(G.rebirth + delta, 1, S.maxRebirth)
            UI.save()
            UI.paintGoal()
        end)
    end
    rebStep("–", 14, -1)
    rebStep("+", 48, 1)
    rebStep("MAX", 82, 999)

    -- skill tree
    el.gUpg = UI.goalCard(cards, 2, "Skill tree", function()
        return G.needUpgrades
    end, function(v)
        G.needUpgrades = v
        UI.save()
        UI.paintGoal()
    end)
    UI.smallButton(el.gUpg.card, "Edit tree  ›", { AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 14, 1, -10),
        Size = UDim2.fromOffset(86, 26), TextSize = 11 }, function()
        UI.select("Skill Tree")
    end)
    UI.label("give up", 10, TH.Dim, TH.Font, { AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, -78, 1, -16),
        Size = UDim2.fromOffset(40, 14), TextXAlignment = Enum.TextXAlignment.Right, Parent = el.gUpg.card })
    el.gGiveUp = UI.new("TextBox", { AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, -12, 1, -10), Size = UDim2.fromOffset(62, 26),
        BackgroundColor3 = TH.Bg, Text = "", TextSize = 11, Font = TH.Bold, TextColor3 = TH.Text, ClearTextOnFocus = true, ZIndex = 3,
        Parent = el.gUpg.card }, { UI.corner(6) })
    UI.track(el.gGiveUp.FocusLost:Connect(function()
        local n = tonumber((string.gsub(el.gGiveUp.Text, "%D", "")))
        G.giveUp = n and math.clamp(n, 0, 600) or 0
        UI.save()
        UI.paintGoal()
    end))

    -- dice
    el.gDice = UI.goalCard(cards, 3, "Dice", function()
        return G.needDice
    end, function(v)
        G.needDice = v
        UI.save()
        UI.paintGoal()
    end)
    el.gDiceImg = UI.new("ImageLabel", { BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, -10, 1, -8),
        Size = UDim2.fromOffset(40, 40), Parent = el.gDice.card })
    el.gDice.value.Size = UDim2.new(1, -28, 0, 24)

    UI.label("PICK THE TARGET DICE  ·  owning it, or any dice with more luck, counts", 10, TH.Dim, TH.Bold,
        { Position = UDim2.fromOffset(0, 148), Size = UDim2.new(1, 0, 0, 14), Parent = page })
    el.diceList = UI.scroller(page, { Position = UDim2.fromOffset(0, 168), Size = UDim2.new(1, 0, 1, -168) })
    UI.new("UIGridLayout", { CellSize = UDim2.fromOffset(124, 158), CellPadding = UDim2.fromOffset(9, 9),
        SortOrder = Enum.SortOrder.LayoutOrder, Parent = el.diceList })
    UI.diceTiles = {}
    UI.diceBuild = 1
    UI.paintGoal()
end

-- one dice tile: light ray in the rarity colours, the dice image, name, rarity, luck
function UI.diceCard(parent, d, order)
    local r = nil
    pcall(function()
        r = M.Rarities.Get(d.cfg.rarity)
    end)
    local grad = r and r.gradient or ColorSequence.new(TH.Sub)
    local f = UI.new("TextButton", { AutoButtonColor = false, Text = "", BackgroundColor3 = TH.Panel, LayoutOrder = order, Parent = parent },
        { UI.corner(12), UI.new("UIScale", {}) })
    local st = UI.stroke(TH.Stroke)
    st.Parent = f
    local well = UI.new("Frame", { BackgroundColor3 = TH.Bg, Position = UDim2.fromOffset(7, 7), Size = UDim2.new(1, -14, 0, 92),
        ClipsDescendants = true, Parent = f }, { UI.corner(10) })
    UI.new("UIGradient", { Color = grad, Rotation = 90, Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.92),
        NumberSequenceKeypoint.new(1, 0.7) }), Parent = UI.new("Frame", { BackgroundColor3 = Color3.new(1, 1, 1), Size = UDim2.fromScale(1, 1),
        BorderSizePixel = 0, Parent = well }, { UI.corner(10) }) })
    local ray = UI.new("ImageLabel", { BackgroundTransparency = 1, Image = LIGHT_RAY, AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(150, 150), ImageTransparency = 0.45, Parent = well },
        { UI.new("UIGradient", { Color = grad }) })
    local img = UI.new("ImageLabel", { BackgroundTransparency = 1, Image = d.cfg.image or "", AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(68, 68), Parent = well }, { UI.new("UIScale", {}) })
    local owned = UI.new("Frame", { BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 0.5, Size = UDim2.fromScale(1, 1),
        Visible = false, ZIndex = 4, Parent = well }, { UI.corner(10) })
    local tick = UI.new("TextLabel", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(52, 52),
        BackgroundColor3 = TH.Good, Text = "✓", TextSize = 32, Font = TH.Bold, TextColor3 = Color3.new(1, 1, 1), ZIndex = 5, Parent = owned },
        { UI.corner(), UI.new("UIStroke", { Color = Color3.new(1, 1, 1), Thickness = 3, Transparency = 0.2 }), UI.new("UIScale", {}),
          UI.new("UIGradient", { Rotation = 90, Color = ColorSequence.new(Color3.new(1, 1, 1), Color3.fromRGB(170, 200, 180)) }) })
    local check = UI.chip(well, "TARGET", TH.Accent, { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -5, 0, 5), Visible = false,
        ZIndex = 3, BackgroundTransparency = 0.1, TextColor3 = TH.Text, TextSize = 10, Size = UDim2.fromOffset(0, 18) })
    UI.label(d.name, 12, TH.Text, TH.Bold, { Position = UDim2.fromOffset(6, 104), Size = UDim2.new(1, -12, 0, 15),
        TextXAlignment = Enum.TextXAlignment.Center, Parent = f })
    local rl = UI.label(tostring(d.cfg.rarity), 11, Color3.new(1, 1, 1), TH.Bold, { Position = UDim2.fromOffset(6, 120),
        Size = UDim2.new(1, -12, 0, 14), TextXAlignment = Enum.TextXAlignment.Center, Parent = f })
    UI.new("UIGradient", { Color = grad, Parent = rl })
    UI.label(H.fmt(d.luck) .. "x luck · $" .. H.fmt(d.price), 10, TH.Sub, TH.Font, { Position = UDim2.fromOffset(6, 136), Size = UDim2.new(1, -12, 0, 13),
        TextXAlignment = Enum.TextXAlignment.Center, Parent = f })
    local sc = f:FindFirstChildOfClass("UIScale")
    local isc = img:FindFirstChildOfClass("UIScale")
    UI.track(f.MouseEnter:Connect(function()
        UI.tween(isc, MOTION.Spring, { Scale = 1.15 })
        UI.tween(ray, MOTION.Base, { ImageTransparency = 0.1 })
    end))
    UI.track(f.MouseLeave:Connect(function()
        UI.tween(isc, MOTION.Base, { Scale = 1 })
        UI.tween(ray, MOTION.Base, { ImageTransparency = 0.45 })
    end))
    UI.track(f.Activated:Connect(function()
        G.dice = d.name
        G.needDice = true
        UI.save()
        UI.paintGoal()
        sc.Scale = 0.93
        UI.tween(sc, MOTION.Spring, { Scale = 1 })
        UI.toast("Goal dice: " .. d.name, "Good")
    end))
    UI.diceTiles[d.name] = { stroke = st, check = check, owned = owned, tickScale = tick:FindFirstChildOfClass("UIScale"), ray = ray, frame = f,
        wasOwned = false }
end

function UI.buildDiceCards()
    local list = UI.diceList()
    local made = 0
    while UI.diceBuild and UI.diceBuild <= #list and made < 8 do
        local i = UI.diceBuild
        UI.diceCard(UI.el.diceList, list[i], i)
        UI.diceBuild = i + 1
        made = made + 1
    end
    if UI.diceBuild and UI.diceBuild > #list then
        UI.diceBuild = nil
        UI.paintGoal()
    end
end

function UI.paintGoal()
    local el = UI.el
    if not el.gReb then
        return
    end
    el.gReb.value.Text = "Rebirth " .. G.rebirth .. " / " .. S.maxRebirth
    el.gReb.sub.Text = "now " .. D.Rebirth()
    el.gGiveUp.Text = G.giveUp > 0 and (G.giveUp .. " min") or "never"
    local have, total = UI.upgradeFrac()
    el.gUpg.value.Text = have .. " / " .. total .. " owned"
    el.gUpg.sub.Text = (G.upgrades and #G.upgrades > 0) and (total .. " picked in Skill Tree") or "all upgrades required"
    el.gDice.value.Text = tostring(G.dice)
    local cfg = M.Dice.GetAll()[G.dice]
    el.gDiceImg.Image = cfg and cfg.image or ""
    el.gDiceImg.ImageTransparency = G.needDice and 0 or 0.6
    el.gDice.sub.Text = H.hasGoalDice() and "✓ owned" or (cfg and ("$" .. H.fmt(cfg.price or 0)) or "")
    el.gReb.paint()
    el.gUpg.paint()
    el.gDice.paint()
    local owned = D.OwnedDice() or {}
    for name, t in pairs(UI.diceTiles) do
        local on = name == G.dice and G.needDice
        t.check.Visible = on
        local isOwned = owned[name] == true or name == D.Dice()
        t.owned.Visible = isOwned
        if isOwned and not t.wasOwned then
            t.tickScale.Scale = 0.2
            UI.tween(t.tickScale, MOTION.Spring, { Scale = 1 })
        end
        t.wasOwned = isOwned
        t.stroke.Color = on and TH.Accent or TH.Stroke
        t.stroke.Thickness = on and 2 or 1
        if on then
            UI.goalTile = t
        end
    end
    local parts = {}
    if G.needDice then
        table.insert(parts, "owns " .. tostring(G.dice))
    end
    if G.needRebirth then
        table.insert(parts, "rebirth " .. G.rebirth)
    end
    if G.needUpgrades then
        table.insert(parts, "skill tree " .. total .. (G.giveUp > 0 and (" (or stuck " .. G.giveUp .. " min)") or ""))
    end
    el.goalSummary.Text = #parts > 0 and ("Maxed when: " .. table.concat(parts, "  +  ")) or "No goal set - the builder sends right away"
    el.goalSummary.TextColor3 = #parts > 0 and TH.Text or TH.Warn
end

-- ── Potions page: one row per potion type, click a tier to drink it or skip it ──
function UI.buildPotions(page)
    local el = UI.el
    local top = UI.new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 40), Parent = page })
    UI.potFilter = "All"
    el.potSeg = UI.segmented(top, { "All", "I", "II", "III", "IV" }, function()
        return UI.potFilter
    end, function(v)
        UI.potFilter = v
        el.potSeg.paint()
        UI.paintPotions()
    end, { Size = UDim2.fromOffset(5 * 58 + 6, 40) }, 58)
    UI.label("TIER", 10, TH.Dim, TH.Bold, { Position = UDim2.fromOffset(5 * 58 + 18, 0), Size = UDim2.fromOffset(40, 40), Parent = top })

    -- Lucky Spin: a coloured card with the game's spin icon and a switch
    local spin = UI.new("TextButton", { AutoButtonColor = false, Text = "", AnchorPoint = Vector2.new(1, 0), Position = UDim2.fromScale(1, 0),
        Size = UDim2.fromOffset(214, 40), BackgroundColor3 = Color3.new(1, 1, 1), Parent = top }, { UI.corner(12), UI.new("UIScale", {}) })
    el.spinGrad = UI.new("UIGradient", { Rotation = 0, Parent = spin })
    el.spinEdge = UI.new("UIStroke", { Color = Color3.new(1, 1, 1), Transparency = 0.6, Thickness = 1.5, Parent = spin })
    local spinImg = ""
    pcall(function()
        spinImg = M.Entry.getEntryConfig("Lucky Spin").image or ""
    end)
    UI.new("ImageLabel", { BackgroundTransparency = 1, Image = spinImg, Position = UDim2.fromOffset(6, 2), Size = UDim2.fromOffset(36, 36), Parent = spin })
    UI.label("Lucky Spin", 13, TH.Text, TH.Bold, { Position = UDim2.fromOffset(48, 4), Size = UDim2.fromOffset(110, 18),
        TextStrokeTransparency = 0.6, Parent = spin })
    el.spinState = UI.label("", 10, TH.Text, TH.Bold, { Position = UDim2.fromOffset(48, 21), Size = UDim2.fromOffset(110, 14),
        TextTransparency = 0.25, Parent = spin })
    local track = UI.new("Frame", { AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -12, 0.5, 0), Size = UDim2.fromOffset(40, 22),
        BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 0.55, Parent = spin }, { UI.corner() })
    local knob = UI.new("Frame", { AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 3, 0.5, 0), Size = UDim2.fromOffset(16, 16),
        BackgroundColor3 = Color3.new(1, 1, 1), Parent = track }, { UI.corner() })
    local spinScale = spin:FindFirstChildOfClass("UIScale")
    el.spinToggle = { paint = function()
        local on = G.spins
        el.spinGrad.Color = on and ColorSequence.new({ ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 92, 170)),
            ColorSequenceKeypoint.new(0.5, Color3.fromRGB(190, 110, 255)), ColorSequenceKeypoint.new(1, Color3.fromRGB(90, 140, 255)) })
            or ColorSequence.new(TH.Elevated, TH.Panel)
        el.spinState.Text = on and "ON · used when no spin is running" or "OFF"
        UI.tween(knob, MOTION.Spring, { Position = on and UDim2.new(1, -19, 0.5, 0) or UDim2.new(0, 3, 0.5, 0) })
        UI.tween(track, MOTION.Base, { BackgroundTransparency = on and 0.35 or 0.55 })
    end }
    UI.track(spin.Activated:Connect(function()
        G.spins = not G.spins
        UI.save()
        el.spinToggle.paint()
        spinScale.Scale = 0.95
        UI.tween(spinScale, MOTION.Spring, { Scale = 1 })
    end))
    el.spinToggle.paint()
    el.potSummary = UI.label("", 12, TH.Text, TH.Bold, { Position = UDim2.fromOffset(0, 48), Size = UDim2.new(1, 0, 0, 18), Parent = page })
    el.potList = UI.scroller(page, { Position = UDim2.fromOffset(0, 72), Size = UDim2.new(1, 0, 1, -72) })
    UI.new("UIListLayout", { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder, Parent = el.potList })
    UI.potTiles = {}
    UI.potRows = {}
    -- one section per tier (I → IV), each potion type inside it
    local groups, order = {}, {}
    for _, p in ipairs(UI.potionList()) do
        if not groups[p.tier] then
            groups[p.tier] = {}
            table.insert(order, p.tier)
        end
        table.insert(groups[p.tier], p)
    end
    table.sort(order)
    for gi, tierNum in ipairs(order) do
        local list = groups[tierNum]
        table.sort(list, function(a, b)
            return a.category < b.category
        end)
        local sec = UI.new("Frame", { BackgroundColor3 = TH.Panel, Size = UDim2.new(1, -2, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
            LayoutOrder = gi, Parent = el.potList }, { UI.corner(12), UI.stroke(),
            UI.new("UIPadding", { PaddingBottom = UDim.new(0, 12) }) })
        UI.label("TIER " .. list[1].tierName, 15, TH.Text, TH.Bold, { Position = UDim2.fromOffset(14, 12), Size = UDim2.fromOffset(90, 20), Parent = sec })
        local info = UI.label("", 11, TH.Sub, TH.Font, { Position = UDim2.fromOffset(104, 14), Size = UDim2.fromOffset(200, 16), Parent = sec })
        UI.smallButton(sec, "toggle tier", { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -12, 0, 10), Size = UDim2.fromOffset(90, 24),
            TextSize = 10 }, function()
            local anyOn = false
            for _, p in ipairs(list) do
                if not G.potionOff[p.name] then
                    anyOn = true
                end
            end
            for _, p in ipairs(list) do
                G.potionOff[p.name] = anyOn or nil
            end
            UI.save()
            UI.paintPotions()
        end)
        local grid = UI.new("Frame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(12, 44), Size = UDim2.new(1, -24, 0, 0),
            AutomaticSize = Enum.AutomaticSize.Y, Parent = sec },
            { UI.new("UIGridLayout", { CellSize = UDim2.fromOffset(122, 146), CellPadding = UDim2.fromOffset(9, 9),
                SortOrder = Enum.SortOrder.LayoutOrder }) })
        UI.potRows[gi] = { info = info, list = list, sec = sec, tierName = list[1].tierName }
        for ti, p in ipairs(list) do
            local t = UI.new("TextButton", { AutoButtonColor = false, Text = "", BackgroundColor3 = TH.Bg, LayoutOrder = ti, Parent = grid },
                { UI.corner(12), UI.new("UIScale", {}) })
            local st = UI.stroke(TH.Stroke)
            st.Parent = t
            -- the game's own item icon (rarity frame), same as the backpack / Trade Hub
            local well = UI.new("Frame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(8, 8), Size = UDim2.new(1, -16, 0, 96),
                Parent = t })
            local holder = UI.new("Frame", { BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5),
                Size = UDim2.fromOffset(96, 96), Parent = well })
            UI.new("ImageLabel", { Name = "Placeholder", BackgroundTransparency = 1, Image = p.cfg.image or "", AnchorPoint = Vector2.new(0.5, 0.5),
                Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(60, 60), Parent = holder })
            if M.EntryIcon then
                ICON.request(p.name, holder)
            end
            local shade = UI.new("Frame", { BackgroundColor3 = TH.Bg, BackgroundTransparency = 0.35, Size = UDim2.fromScale(1, 1), ZIndex = 8,
                Visible = false, Parent = well }, { UI.corner(10) })
            UI.label("SKIP", 14, TH.Bad, TH.Bold, { Size = UDim2.fromScale(1, 1), TextXAlignment = Enum.TextXAlignment.Center, ZIndex = 9,
                Parent = shade })
            local count = UI.chip(well, "", TH.Good, { Position = UDim2.fromOffset(4, 4), Size = UDim2.fromOffset(0, 16), TextSize = 10, ZIndex = 10 })
            local tier = UI.label(p.name, 11, TH.Text, TH.Bold, { Position = UDim2.fromOffset(6, 110), Size = UDim2.new(1, -12, 0, 14),
                TextXAlignment = Enum.TextXAlignment.Center, Parent = t })
            local state = UI.label("", 10, TH.Good, TH.Bold, { Position = UDim2.fromOffset(6, 126), Size = UDim2.new(1, -12, 0, 13),
                TextXAlignment = Enum.TextXAlignment.Center, Parent = t })
            UI.potTiles[p.name] = { frame = t, stroke = st, shade = shade, tier = tier, state = state, count = count }
            local sc = t:FindFirstChildOfClass("UIScale")
            UI.track(t.MouseEnter:Connect(function()
                UI.tween(st, MOTION.Fast, { Color = TH.Accent })
            end))
            UI.track(t.MouseLeave:Connect(function()
                UI.tween(st, MOTION.Fast, { Color = TH.Stroke })
            end))
            UI.track(t.Activated:Connect(function()
                G.potionOff[p.name] = (not G.potionOff[p.name]) or nil
                UI.save()
                UI.paintPotions()
                sc.Scale = 0.92
                UI.tween(sc, MOTION.Spring, { Scale = 1 })
            end))
        end
    end
    UI.paintPotions()
end

function UI.potionCounts()
    local counts = {}
    for _, e in pairs(D.Inventory() or {}) do
        if type(e) == "table" and e.name then
            counts[e.name] = (counts[e.name] or 0) + (tonumber(e.amount) or 1)
        end
    end
    return counts
end

function UI.paintPotions()
    local counts = UI.potionCounts()
    local on, total = 0, 0
    for name, t in pairs(UI.potTiles or {}) do
        total = total + 1
        local enabled = not G.potionOff[name]
        if enabled then
            on = on + 1
        end
        local have = counts[name] or 0
        t.count.Text = "x" .. H.fmt(have)
        t.count.TextColor3 = have > 0 and TH.Good or TH.Dim
        t.count.BackgroundColor3 = have > 0 and TH.Good or TH.Dim
        t.state.Text = enabled and "DRINK" or "SKIP"
        t.state.TextColor3 = enabled and TH.Good or TH.Bad
        t.shade.Visible = not enabled
        t.tier.TextColor3 = enabled and TH.Text or TH.Dim
    end
    for _, r in pairs(UI.potRows or {}) do
        local n = 0
        for _, p in ipairs(r.list) do
            if not G.potionOff[p.name] then
                n = n + 1
            end
        end
        r.info.Text = n .. " / " .. #r.list .. " on"
        r.info.TextColor3 = n > 0 and TH.Good or TH.Dim
        r.sec.Visible = UI.potFilter == "All" or UI.potFilter == r.tierName
    end
    if UI.el.spinToggle then
        UI.el.spinToggle.paint()
    end
    UI.el.potSummary.Text = on .. " / " .. total .. " potions will be drunk" .. (CFG.Farm.AutoItems and "" or "  (Auto items is OFF in Farm)")
    UI.el.potSummary.TextColor3 = CFG.Farm.AutoItems and TH.Text or TH.Warn
end

-- ── Tower page: one card per tower, the tower art is the card ──
local DIFF_COLOR = {
    Easy = Color3.fromRGB(74, 210, 128), Medium = Color3.fromRGB(240, 200, 64), Hard = Color3.fromRGB(245, 140, 60),
    Extreme = Color3.fromRGB(232, 82, 92), Nightmare = Color3.fromRGB(190, 110, 255), Abyssal = Color3.fromRGB(90, 120, 255),
    Godly = Color3.fromRGB(255, 215, 90),
}

function UI.buildTower(page)
    local el = UI.el
    local top = UI.new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 36), Parent = page })
    el.tPick = UI.segmented(top, { "best", "list" }, function()
        return CFG.Tower.Pick == "list" and "list" or "best"
    end, function(v)
        CFG.Tower.Pick = v
        GL.capture()
        G.tower.pick = v
        UI.save()
        UI.paintTower(false)
    end, nil, 80)
    local infHolder = UI.new("Frame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(176, 0), Size = UDim2.fromOffset(190, 36), Parent = top })
    el.tInf = UI.toggle(infHolder, "Infinity Tower", function()
        return CFG.Tower.Infinity
    end, function(v)
        CFG.Tower.Infinity = v
        GL.capture()
        G.tower.infinity = v
        UI.save()
        UI.paintTower(false)
    end)
    el.tInf.row.Size = UDim2.fromScale(1, 1)
    UI.button(top, "Clear picks", TH.Panel, { Position = UDim2.fromOffset(374, 0), Size = UDim2.fromOffset(110, 36), TextColor3 = TH.Bad }, function()
        CFG.Tower.Only = {}
        GL.capture()
        G.tower.only = {}
        UI.save()
        UI.paintTower(false)
    end)
    local onHolder = UI.new("Frame", { BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0), Position = UDim2.fromScale(1, 0),
        Size = UDim2.fromOffset(150, 36), Parent = top })
    el.tOn = UI.toggle(onHolder, "Towers on", function()
        return S.towerOn
    end, function(v)
        S.towerOn = v
    end)
    el.tOn.row.Size = UDim2.fromScale(1, 1)
    el.tSummary = UI.label("", 12, TH.Text, TH.Bold, { Position = UDim2.fromOffset(0, 44), Size = UDim2.new(1, 0, 0, 18), Parent = page })
    el.tList = UI.scroller(page, { Position = UDim2.fromOffset(0, 68), Size = UDim2.new(1, 0, 1, -68) })
    UI.new("UIGridLayout", { CellSize = UDim2.new(0.5, -6, 0, 124), CellPadding = UDim2.fromOffset(8, 8),
        SortOrder = Enum.SortOrder.LayoutOrder, Parent = el.tList })
    UI.towerRows = {}
    local list = {}
    for name, cfg in pairs(M.Towers.GetAll()) do
        table.insert(list, { name = name, cfg = cfg, order = cfg.order or 0 })
    end
    table.sort(list, function(a, b)
        return a.order < b.order
    end)
    for i, tw in ipairs(list) do
        local f = UI.new("TextButton", { AutoButtonColor = false, Text = "", BackgroundTransparency = 1, LayoutOrder = i, Parent = el.tList },
            { UI.corner(12), UI.new("UIScale", {}) })
        local cg = UI.new("CanvasGroup", { BackgroundColor3 = TH.Bg, Size = UDim2.fromScale(1, 1), Parent = f }, { UI.corner(12) })
        -- the art fills the card; a dark fade on the left keeps the text readable
        local art = UI.new("ImageLabel", { BackgroundTransparency = 1, Image = tw.cfg.image or "", ScaleType = Enum.ScaleType.Crop,
            AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(1, 1), Parent = cg },
            { UI.corner(12), UI.new("UIScale", {}) })
        UI.new("Frame", { BackgroundColor3 = Color3.new(0, 0, 0), BorderSizePixel = 0, Size = UDim2.fromScale(1, 1), Parent = cg },
            { UI.corner(12), UI.new("UIGradient", { Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.05),
                NumberSequenceKeypoint.new(0.55, 0.45), NumberSequenceKeypoint.new(1, 0.85) }) }) })
        local diffName = tw.cfg.difficulty and tw.cfg.difficulty.name or ""
        local dc = DIFF_COLOR[diffName] or TH.Sub
        UI.label(tw.name, 17, TH.Text, TH.Bold, { Position = UDim2.fromOffset(14, 14), Size = UDim2.new(1, -110, 0, 22),
            TextStrokeTransparency = 0.5, Parent = cg })
        UI.chip(cg, tostring(diffName ~= "" and diffName or (tw.cfg.event and "Event" or "Tower")), dc,
            { Position = UDim2.fromOffset(14, 42), BackgroundTransparency = 0.55, TextColor3 = TH.Text })
        UI.label(tw.cfg.maxFloors and (tw.cfg.maxFloors .. " floors") or "endless", 11, TH.Sub, TH.Bold,
            { Position = UDim2.fromOffset(14, 66), Size = UDim2.fromOffset(160, 14), TextStrokeTransparency = 0.6, Parent = cg })
        local sim = UI.label("", 12, TH.Good, TH.Bold, { Position = UDim2.fromOffset(14, 92), Size = UDim2.new(1, -28, 0, 16),
            TextStrokeTransparency = 0.5, Parent = cg })
        local barBg = UI.new("Frame", { BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 0.5, AnchorPoint = Vector2.new(0, 1),
            Position = UDim2.new(0, 0, 1, 0), Size = UDim2.new(1, 0, 0, 3), BorderSizePixel = 0, Parent = cg })
        local bar = UI.new("Frame", { BackgroundColor3 = TH.Good, BorderSizePixel = 0, Size = UDim2.fromScale(0, 1), Parent = barBg })
        local pill = UI.chip(cg, "", TH.Dim, { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -12, 0, 12), BackgroundTransparency = 0.25,
            TextColor3 = TH.Text })
        local now = UI.chip(cg, "● RUNNING", TH.Warn, { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -12, 0, 38), Visible = false,
            BackgroundTransparency = 0.25, TextColor3 = TH.Text })
        local stroke = UI.new("UIStroke", { Color = Color3.new(1, 1, 1), Thickness = 2, Transparency = 0.85, Parent = f })
        local glow = UI.new("UIGradient", { Parent = stroke })
        UI.towerRows[tw.name] = { frame = f, art = art, stroke = stroke, glow = glow, sim = sim, bar = bar, pill = pill, now = now, cfg = tw.cfg }
        local asc = art:FindFirstChildOfClass("UIScale")
        local fsc = f:FindFirstChildOfClass("UIScale")
        UI.track(f.MouseEnter:Connect(function()
            UI.tween(asc, MOTION.Slow, { Scale = 1.08 })
        end))
        UI.track(f.MouseLeave:Connect(function()
            UI.tween(asc, MOTION.Slow, { Scale = 1 })
        end))
        UI.track(f.Activated:Connect(function()
            local only = table.clone(CFG.Tower.Only)
            local idx = table.find(only, tw.name)
            if idx then
                table.remove(only, idx)
            else
                table.insert(only, tw.name)
            end
            CFG.Tower.Only = only
            GL.capture()
            G.tower.only = only
            UI.save()
            fsc.Scale = 0.95
            UI.tween(fsc, MOTION.Spring, { Scale = 1 })
            UI.paintTower(false)
        end))
    end
    UI.paintTower(true)
end

function UI.paintTower(withSim)
    local el = UI.el
    local only = H.set(CFG.Tower.Only)
    local any = #CFG.Tower.Only > 0
    local team = withSim and SYS.team() or nil
    for name, r in pairs(UI.towerRows) do
        local inList = only[name] == true
        local allowed = any and inList or (not any and not r.cfg.event)
        if name == "Infinity Tower" and not CFG.Tower.Infinity then
            allowed = false
        end
        local pos = inList and table.find(CFG.Tower.Only, name)
        r.pill.Text = inList and ("#" .. pos .. " PICKED") or (allowed and "AUTO" or "SKIP")
        local c = inList and TH.Accent or (allowed and TH.Good or TH.Dim)
        r.pill.BackgroundColor3 = c
        r.pill.TextColor3 = allowed and TH.Text or TH.Sub
        r.picked = inList
        r.stroke.Transparency = inList and 0 or (allowed and 0.75 or 0.9)
        if not inList then
            r.glow.Color = ColorSequence.new(Color3.new(1, 1, 1))
        end
        UI.tween(r.art, MOTION.Base, { ImageTransparency = allowed and 0 or 0.65 })
        r.now.Visible = S.towerOn and S.tower.name == name
        if team and #team > 0 then
            local ok, floors = pcall(SYS.simTower, r.cfg, team)
            floors = ok and floors or 0
            local max = r.cfg.maxFloors
            r.sim.Text = "team clears " .. floors .. (max and (" / " .. max) or " floors")
            local full = max and floors >= max
            r.sim.TextColor3 = full and TH.Good or (floors > 0 and TH.Warn or TH.Bad)
            r.bar.BackgroundColor3 = r.sim.TextColor3
            UI.tween(r.bar, MOTION.Slow, { Size = UDim2.fromScale(max and math.clamp(floors / max, 0, 1) or math.clamp(floors / 100, 0, 1), 1) })
        elseif team then
            r.sim.Text = "no tower team yet"
            r.sim.TextColor3 = TH.Sub
        end
    end
    el.tPick.paint()
    el.tInf.paint()
    el.tOn.paint()
    el.tSummary.Text = (CFG.Tower.Pick == "list" and "List: runs the picked towers in turn" or "Best: the hardest tower the team fully clears")
        .. (any and (" · only the " .. #CFG.Tower.Only .. " picked") or " · click a card to limit it to picked towers")
        .. "  ·  now: " .. tostring(S.tower.name)
end

-- picked cards get a slowly turning light around the edge
function UI.animTower(t)
    for _, r in pairs(UI.towerRows or {}) do
        if r.picked then
            r.glow.Color = ColorSequence.new({ ColorSequenceKeypoint.new(0, TH.Accent), ColorSequenceKeypoint.new(0.5, Color3.new(1, 1, 1)),
                ColorSequenceKeypoint.new(1, TH.Accent) })
            r.glow.Rotation = (t * 90) % 360
        end
        if r.now.Visible then
            r.now.BackgroundTransparency = 0.25 + (math.sin(t * 4) + 1) * 0.25
        end
    end
end

-- ── Skill Tree page: the game's tree, click tiles to require them ──
local TREE_OWNED_BG = "rbxassetid://121829442861416"   -- from UpgradeController (owned tile)
local TREE_OPEN_BG = "rbxassetid://118987660331960"    -- from UpgradeController (available tile)
local TREE_HEX_R = 96    -- tile hex is 1.2 x 150 = 180 px wide (Upgrades.Screen.Template, dump 2026-11-02)

function UI.isRequired(name)
    if not G.upgrades or #G.upgrades == 0 then
        return true
    end
    return table.find(G.upgrades, name) ~= nil
end

function UI.buildTree(page)
    local el = UI.el
    local bar = UI.new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 36), Parent = page })
    el.treeInfo = UI.label("", 12, TH.Text, TH.Bold, { Size = UDim2.new(1, -470, 1, 0), Parent = bar })
    UI.button(bar, "Fit", TH.Panel, { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -356, 0, 0),
        Size = UDim2.fromOffset(90, 36) }, function()
        UI.fitTree()
    end)
    UI.button(bar, "Require all", TH.Accent, { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -228, 0, 0),
        Size = UDim2.fromOffset(122, 36) }, function()
        G.upgrades = nil
        UI.save()
        UI.paintTree()
    end)
    UI.button(bar, "Only owned", TH.Panel, { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -98, 0, 0),
        Size = UDim2.fromOffset(122, 36) }, function()
        local owned = D.Upgrades() or {}
        local list = {}
        for name in pairs(M.Upgrades) do
            if name ~= "Start" and owned[name] then
                table.insert(list, name)
            end
        end
        G.upgrades = list
        UI.save()
        UI.paintTree()
    end)
    UI.button(bar, "Clear", TH.Panel, { AnchorPoint = Vector2.new(1, 0), Position = UDim2.fromScale(1, 0),
        Size = UDim2.fromOffset(90, 36), TextColor3 = TH.Bad }, function()
        G.upgrades = { "Start" }
        UI.save()
        UI.paintTree()
    end)
    -- viewport (pan with drag, zoom with the mouse wheel - same feel as the game)
    local vp = UI.new("Frame", { BackgroundColor3 = TH.Panel, Position = UDim2.fromOffset(0, 46), Size = UDim2.new(1, 0, 1, -76),
        ClipsDescendants = true, Active = true, Parent = page }, { UI.corner(12), UI.stroke() })
    el.treeVp = vp
    el.treeCanvas = UI.new("Frame", { BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5),
        Size = UDim2.fromScale(1, 1), Parent = vp }, { UI.new("UIScale", { Scale = 0.5 }) })
    el.treeScale = el.treeCanvas:FindFirstChildOfClass("UIScale")
    el.treeHint = UI.label(UI.TREE_HINT, 11, TH.Dim, TH.Font, {
        AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Size = UDim2.new(1, 0, 0, 22), Parent = page })
    do
        local dragging, startMouse, startPos = false, nil, nil
        UI.track(vp.InputBegan:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
                dragging = true
                startMouse = input.Position
                startPos = el.treeCanvas.Position
            end
        end))
        UI.track(UserInputService.InputEnded:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
                dragging = false
            end
        end))
        UI.track(UserInputService.InputChanged:Connect(function(input)
            if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
                local d = input.Position - startMouse
                el.treeCanvas.Position = UDim2.new(0.5, startPos.X.Offset + d.X, 0.5, startPos.Y.Offset + d.Y)
            end
        end))
        UI.track(UserInputService.InputChanged:Connect(function(input)
            if input.UserInputType ~= Enum.UserInputType.MouseWheel or not vp.Visible or not UI.tab or UI.tab.name ~= "Skill Tree" then
                return
            end
            local m = UserInputService:GetMouseLocation() - game:GetService("GuiService"):GetGuiInset()
            local a, sz = vp.AbsolutePosition, vp.AbsoluteSize
            if m.X >= a.X and m.Y >= a.Y and m.X <= a.X + sz.X and m.Y <= a.Y + sz.Y then
                UI.zoomTree(1.15 ^ input.Position.Z)
            end
        end))
    end
    UI.smallButton(vp, "+", { AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, -10, 1, -44), Size = UDim2.fromOffset(30, 30),
        ZIndex = 40 }, function()
        UI.zoomTree(1.25)
    end)
    UI.smallButton(vp, "–", { AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, -10, 1, -10), Size = UDim2.fromOffset(30, 30),
        ZIndex = 40 }, function()
        UI.zoomTree(0.8)
    end)
    UI.treeTiles = {}
    UI.treeBuilt = false
end

function UI.zoomTree(mult)
    local sc = UI.el.treeScale
    sc.Scale = math.clamp(sc.Scale * mult, 0.12, 1.5)
end

UI.TREE_HINT = "drag to move · mouse wheel to zoom · click a tile to require it / not"

function UI.fitTree()
    local ext = UI.treeExtent
    if not ext then
        return
    end
    local vpSize = UI.el.treeVp.AbsoluteSize
    local fit = math.min((vpSize.X / UI.el.scale.Scale) / (ext.x * 2 + 200), (vpSize.Y / UI.el.scale.Scale) / (ext.y * 2 + 200))
    UI.tween(UI.el.treeScale, MOTION.Slow, { Scale = math.clamp(fit, 0.12, 1) })
    UI.tween(UI.el.treeCanvas, MOTION.Slow, { Position = UDim2.fromScale(0.5, 0.5) })
end

-- builds the whole tree once (first time the tab opens)
function UI.buildTreeTiles()
    if UI.treeBuilt then
        return
    end
    UI.treeBuilt = true
    local canvas = UI.el.treeCanvas
    local tpl = UI.gameTemplate("upgrade")
    local pos = {}
    local maxX, maxY = 0, 0
    for name in pairs(M.Upgrades) do
        local ok, p = pcall(M.Tree.GetPosition, name, UDim2.fromScale(0.5, 0.5))
        if ok and p then
            pos[name] = p
            maxX = math.max(maxX, math.abs(p.X.Offset))
            maxY = math.max(maxY, math.abs(p.Y.Offset))
        end
    end
    -- connecting lines first so tiles sit on top
    for name, p in pairs(pos) do
        local parentName = M.Tree.GetParent(name)
        local pp = parentName and pos[parentName]
        if pp then
            local dx = p.X.Offset - pp.X.Offset
            local dy = p.Y.Offset - pp.Y.Offset
            local len = math.sqrt(dx * dx + dy * dy)
            local line = UI.new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), BorderSizePixel = 0, BackgroundColor3 = TH.Stroke,
                Position = UDim2.new(0.5, (p.X.Offset + pp.X.Offset) / 2, 0.5, (p.Y.Offset + pp.Y.Offset) / 2),
                Size = UDim2.fromOffset(len, 10), Rotation = math.deg(math.atan2(dy, dx)), ZIndex = 1, Parent = canvas }, { UI.corner() })
            UI.treeTiles[name .. "#line"] = { line = line, name = name }
        end
    end
    for name, p in pairs(pos) do
        local up = M.Upgrades[name]
        local tile
        local okTpl = false
        -- hexagon outline behind the tile (flat-top, like the game's hex): six rounded edges
        local glow = UI.new("Frame", { BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Position = p,
            Size = UDim2.fromOffset(2, 2), ZIndex = 2, Parent = canvas })
        for k = 0, 5 do
            local ang = math.rad(k * 60 + 30)
            UI.new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), BorderSizePixel = 0, BackgroundColor3 = Color3.fromRGB(80, 255, 130),
                Position = UDim2.new(0.5, math.cos(ang) * TREE_HEX_R * 0.866, 0.5, math.sin(ang) * TREE_HEX_R * 0.866),
                Size = UDim2.fromOffset(TREE_HEX_R + 8, 10), Rotation = k * 60 + 120, ZIndex = 2, Parent = glow }, { UI.corner() })
        end

        if tpl then
            okTpl = pcall(function()
                local t = tpl:Clone()
                t.Visible = true
                t.Position = p
                local Tile = t.Tile
                Tile.TextLabel.Text = name
                Tile.TextLabel.Visible = true
                Tile.Price.TextLabel.Text = H.fmt(up.price or 0)
                Tile.Price.ImageLabel.Image = M.Images and M.Images.Money or ""
                Tile.ImageLabel.Image = up.image or ""
                -- without the game's style the labels/images keep a white default background
                for _, d in ipairs(t:GetDescendants()) do
                    if d:IsA("GuiObject") then
                        d.BackgroundTransparency = 1
                    end
                    if d:IsA("TextLabel") then
                        d.Font = Enum.Font.FredokaOne
                        d.TextColor3 = Color3.new(1, 1, 1)
                        d.TextStrokeTransparency = 0.2
                    end
                end
                t.BackgroundTransparency = 1
                t.ZIndex = 3
                t.Parent = canvas
                tile = { root = t, bg = Tile, price = Tile.Price }
            end)
        end
        if not okTpl then
            local t = UI.new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = p, Size = UDim2.fromOffset(110, 110),
                BackgroundColor3 = TH.Elevated, ZIndex = 3, Parent = canvas }, { UI.corner(16) })
            UI.new("ImageLabel", { BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 10),
                Size = UDim2.fromOffset(60, 60), Image = up.image or "", Parent = t })
            UI.label(name, 12, TH.Text, TH.Bold, { Position = UDim2.fromOffset(4, 76), Size = UDim2.new(1, -8, 0, 28),
                TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Center, Parent = t })
            tile = { root = t }
        end
        -- overlay: required ring + check, click to toggle
        local ring = UI.new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = p, Size = UDim2.fromOffset(150, 150),
            BackgroundTransparency = 1, ZIndex = 30, Parent = canvas })
        local check = UI.new("TextLabel", { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -8, 0, 4), Size = UDim2.fromOffset(32, 32),
            BackgroundColor3 = TH.Good, Text = "✓", TextSize = 18, Font = TH.Bold, TextColor3 = TH.Bg, ZIndex = 31, Parent = ring },
            { UI.corner() })
        local hit = UI.new("TextButton", { BackgroundTransparency = 1, Text = "", Size = UDim2.fromScale(1, 1), ZIndex = 32, Parent = ring })
        UI.track(hit.MouseEnter:Connect(function()
            local owned = name == "Start" or (D.Upgrades() or {})[name]
            UI.el.treeHint.Text = name .. "  ·  $" .. H.fmt(up.price or 0) .. "  ·  " .. (owned and "owned" or "not owned")
                .. "  ·  " .. ((name ~= "Start" and UI.isRequired(name)) and "REQUIRED" or "not required")
            UI.el.treeHint.TextColor3 = TH.Text
        end))
        UI.track(hit.MouseLeave:Connect(function()
            UI.el.treeHint.Text = UI.TREE_HINT
            UI.el.treeHint.TextColor3 = TH.Dim
        end))
        UI.track(hit.Activated:Connect(function()
            if name == "Start" then
                return
            end
            local list = G.upgrades and #G.upgrades > 0 and table.clone(G.upgrades) or H.requiredUpgrades()
            local idx = table.find(list, name)
            if idx then
                table.remove(list, idx)
            else
                table.insert(list, name)
            end
            G.upgrades = #list > 0 and list or { "Start" }
            UI.save()
            UI.paintTree()
        end))
        tile.ring = glow
        tile.check = check
        UI.treeTiles[name] = tile
    end
    UI.treeExtent = { x = maxX, y = maxY }
    local sp = pos.Start
    UI.el.treeScale.Scale = 0.4
    UI.el.treeCanvas.Position = UDim2.new(0.5, sp and -sp.X.Offset * 0.4 or 0, 0.5, sp and -sp.Y.Offset * 0.4 or 0)
    UI.paintTree()
end

function UI.paintTree()
    if not UI.treeBuilt then
        UI.el.treeInfo.Text = ""
        return
    end
    local owned = D.Upgrades() or {}
    for name, t in pairs(UI.treeTiles) do
        if t.line then
            local req = UI.isRequired(t.name)
            t.line.BackgroundColor3 = req and TH.Good:Lerp(TH.Stroke, 0.25) or TH.Sub:Lerp(TH.Stroke, 0.5)
        else
            local req = name ~= "Start" and UI.isRequired(name)
            if t.bg then
                pcall(function()
                    t.bg.Image = (owned[name] or name == "Start") and TREE_OWNED_BG or TREE_OPEN_BG
                    t.price.Visible = not owned[name] and name ~= "Start"
                end)
            end
            t.ring.Visible = req
            t.check.Visible = req
        end
    end
    local have, total = UI.upgradeFrac()
    UI.el.treeInfo.Text = (G.upgrades and #G.upgrades > 0) and (total .. " required · " .. have .. " owned")
        or ("ALL " .. total .. " required · " .. have .. " owned")
end

-- ── Units page: money makers handed down the chain ──────────
function UI.buildUnits(page)
    local el = UI.el
    local top = UI.new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 36), Parent = page })
    el.uSearch = UI.input(top, "Search units…", { Size = UDim2.new(1, -400, 1, 0) })
    UI.track(el.uSearch:GetPropertyChangedSignal("Text"):Connect(function()
        UI.uSearch = string.lower(el.uSearch.Text)
        UI.unitsDirty = true
    end))
    UI.uOwn = "Owned"
    el.uSeg = UI.segmented(top, { "All", "Owned", "Picked" }, function()
        return UI.uOwn
    end, function(v)
        UI.uOwn = v
        UI.unitsDirty = true
        el.uSeg.paint()
    end, { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -150, 0, 0) }, 76)
    UI.button(top, "Clear picks", TH.Panel, { AnchorPoint = Vector2.new(1, 0), Position = UDim2.fromScale(1, 0),
        Size = UDim2.fromOffset(140, 36), TextColor3 = TH.Bad }, function()
        G.units = {}
        CFG.Chain.Units = G.units
        UI.save()
        UI.unitsDirty = true
    end)
    el.uSummary = UI.label("", 12, TH.Text, TH.Bold, { Position = UDim2.fromOffset(0, 44), Size = UDim2.new(1, 0, 0, 18), Parent = page })
    el.uGrid = UI.scroller(page, { Position = UDim2.fromOffset(0, 68), Size = UDim2.new(1, 0, 1, -68) })
    UI.new("UIGridLayout", { CellSize = UDim2.fromOffset(122, 150), CellPadding = UDim2.fromOffset(10, 10),
        SortOrder = Enum.SortOrder.LayoutOrder, Parent = el.uGrid })
    UI.unitTiles = {}
    UI.unitsDirty = true
end

function UI.unitCatalog()
    if UI.ucat then
        return UI.ucat
    end
    local list = {}
    for name, cfg in pairs(M.Entry.entriesOfKind("Unit")) do
        local ok, inc = pcall(cfg.income, {})
        table.insert(list, { name = name, cfg = cfg, income = ok and inc or 0 })
    end
    table.sort(list, function(a, b)
        return a.income > b.income
    end)
    UI.ucat = list
    return list
end

function UI.renderUnits()
    UI.unitsDirty = false
    local el = UI.el
    local owned = {}
    for _, u in ipairs(H.units()) do
        owned[u.name] = (owned[u.name] or 0) + 1
    end
    local picked = H.set(CFG.Chain.Units)
    local made, shown = 0, 0
    for i, c in ipairs(UI.unitCatalog()) do
        local pass = (UI.uOwn == "All") or (UI.uOwn == "Owned" and owned[c.name]) or (UI.uOwn == "Picked" and picked[c.name])
        if pass and UI.uSearch and UI.uSearch ~= "" and not string.find(string.lower(c.name), UI.uSearch, 1, true) then
            pass = false
        end
        local t = UI.unitTiles[c.name]
        if pass and not t and made < 50 then
            made = made + 1
            local f = UI.new("TextButton", { AutoButtonColor = false, Text = "", BackgroundColor3 = TH.Panel, Parent = el.uGrid },
                { UI.corner(12), UI.new("UIScale", {}) })
            local st = UI.stroke(TH.Stroke)
            st.Parent = f
            local well = UI.new("Frame", { BackgroundColor3 = TH.Bg, Position = UDim2.fromOffset(8, 8), Size = UDim2.new(1, -16, 0, 96),
                ClipsDescendants = true, Parent = f }, { UI.corner(10) })
            local holder = UI.new("Frame", { BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5),
                Size = UDim2.fromOffset(90, 90), Parent = well })
            UI.label(string.upper(string.sub(c.name, 1, 2)), 22, TH.Text, TH.Bold, { Size = UDim2.fromScale(1, 1),
                TextXAlignment = Enum.TextXAlignment.Center, Name = "Placeholder", Parent = holder })
            local check = UI.new("TextLabel", { AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, -6, 1, -6), Size = UDim2.fromOffset(22, 22),
                BackgroundColor3 = TH.Accent, Text = "✓", TextSize = 13, Font = TH.Bold, TextColor3 = TH.Text, ZIndex = 5, Visible = false,
                Parent = well }, { UI.corner() })
            local badge = UI.chip(well, "", TH.Good, { Position = UDim2.fromOffset(5, 5), ZIndex = 5 })
            UI.label(c.name, 11, TH.Text, TH.Bold, { Position = UDim2.fromOffset(6, 108), Size = UDim2.new(1, -12, 0, 14),
                TextXAlignment = Enum.TextXAlignment.Center, Parent = f })
            UI.label("$" .. H.fmt(c.income) .. "/s", 10, TH.Good, TH.Bold, { Position = UDim2.fromOffset(6, 124), Size = UDim2.new(1, -12, 0, 14),
                TextXAlignment = Enum.TextXAlignment.Center, Parent = f })
            t = { frame = f, stroke = st, check = check, badge = badge, holder = holder, icon = false }
            UI.unitTiles[c.name] = t
            local name = c.name
            UI.track(f.Activated:Connect(function()
                local list = table.clone(CFG.Chain.Units)
                local idx = table.find(list, name)
                if idx then
                    table.remove(list, idx)
                else
                    table.insert(list, name)
                end
                G.units = list
                CFG.Chain.Units = list
                UI.save()
                UI.unitsDirty = true
                local sc = f:FindFirstChildOfClass("UIScale")
                sc.Scale = 0.94
                UI.tween(sc, MOTION.Spring, { Scale = 1 })
            end))
        end
        if t then
            t.frame.Visible = pass and true or false
            t.frame.LayoutOrder = i
            local on = picked[c.name] == true
            t.check.Visible = on
            t.stroke.Color = on and TH.Accent or TH.Stroke
            t.stroke.Thickness = on and 2 or 1
            t.badge.Text = owned[c.name] and ("×" .. owned[c.name]) or "×0"
            t.badge.TextColor3 = owned[c.name] and TH.Good or TH.Dim
            if pass then
                shown = shown + 1
                if not t.icon and M.EntryIcon then
                    t.icon = true
                    ICON.request(c.name, t.holder)
                end
            end
        end
    end
    if made >= 50 then
        UI.unitsDirty = true
    end
    local n = #CFG.Chain.Units
    el.uSummary.Text = n > 0 and ("Handed down the chain: " .. table.concat(CFG.Chain.Units, ", "))
        or ("Nothing picked → the top " .. CFG.Chain.TopUnits .. " units by income are handed down")
    el.uSummary.TextColor3 = n > 0 and TH.Text or TH.Warn
end

-- ── Chain page: edit the order + live status ────────────────
function UI.buildChain(page)
    local el = UI.el
    local row = UI.new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 72), Parent = page })
    el.orderBox = UI.input(row, "Paste account names - one per line (or space / comma). They are added to the end of the order.",
        { Size = UDim2.new(1, -150, 1, 0), MultiLine = true, TextWrapped = true, ClipsDescendants = true,
          TextYAlignment = Enum.TextYAlignment.Top, TextSize = 12 })
    local pad = el.orderBox:FindFirstChildOfClass("UIPadding")
    pad.PaddingTop = UDim.new(0, 10)
    UI.button(row, "Add", TH.Accent, { AnchorPoint = Vector2.new(1, 0), Position = UDim2.fromScale(1, 0), Size = UDim2.new(0, 140, 0, 33) }, function()
        local list = table.clone(CFG.Chain.Order)
        local seen = {}
        for _, n in ipairs(list) do
            seen[string.lower(n)] = true
        end
        local added = 0
        for name in string.gmatch(el.orderBox.Text, "[%w_]+") do
            if not seen[string.lower(name)] then
                seen[string.lower(name)] = true
                table.insert(list, name)
                added = added + 1
            end
        end
        el.orderBox.Text = ""
        G.order = list
        CFG.Chain.Order = list
        UI.save()
        UI.rebuildChainRows()
        UI.toast("added " .. added .. " · " .. #list .. " in the chain", "Good")
    end)
    UI.button(row, "Clear order", TH.Panel, { AnchorPoint = Vector2.new(1, 1), Position = UDim2.fromScale(1, 1), Size = UDim2.new(0, 140, 0, 33),
        TextColor3 = TH.Bad }, function()
        if UI.confirmClear and os.clock() - UI.confirmClear < 3 then
            UI.confirmClear = nil
            G.order = {}
            CFG.Chain.Order = G.order
            UI.save()
            UI.rebuildChainRows()
            UI.toast("chain order cleared", "Bad")
        else
            UI.confirmClear = os.clock()
            UI.toast("press Clear order again to remove all " .. #CFG.Chain.Order, "Bad")
        end
    end)
    el.chainHead = UI.label("", 12, TH.Text, TH.Bold, { Position = UDim2.fromOffset(0, 80), Size = UDim2.new(1, 0, 0, 18), Parent = page })
    el.chainList = UI.scroller(page, { Position = UDim2.fromOffset(0, 104), Size = UDim2.new(1, 0, 1, -104) })
    UI.new("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder, Parent = el.chainList })
    UI.rebuildChainRows()
end

function UI.moveInOrder(i, delta)
    local list = table.clone(CFG.Chain.Order)
    local j = i + delta
    if j < 1 or j > #list then
        return
    end
    list[i], list[j] = list[j], list[i]
    G.order = list
    CFG.Chain.Order = list
    UI.save()
    UI.rebuildChainRows()
end

function UI.rebuildChainRows()
    local el = UI.el
    for _, r in ipairs(UI.chainRows) do
        r.frame:Destroy()
    end
    UI.chainRows = {}
    for i, name in ipairs(CFG.Chain.Order) do
        local f = UI.new("Frame", { BackgroundColor3 = TH.Panel, Size = UDim2.new(1, -6, 0, 50), LayoutOrder = i, Parent = el.chainList },
            { UI.corner(10) })
        local st = UI.stroke(TH.Stroke)
        st.Parent = f
        UI.label("#" .. i, 12, TH.Dim, TH.Bold, { Position = UDim2.fromOffset(12, 0), Size = UDim2.fromOffset(34, 50), Parent = f })
        local av = UI.avatar(f, 34, { Position = UDim2.fromOffset(48, 8) })
        UI.label(name, 13, TH.Text, TH.Bold, { Position = UDim2.fromOffset(92, 8), Size = UDim2.new(1, -330, 0, 18), Parent = f })
        local info = UI.label("", 11, TH.Dim, TH.Font, { Position = UDim2.fromOffset(92, 26), Size = UDim2.new(1, -330, 0, 14), Parent = f })
        local pill = UI.chip(f, "OFFLINE", TH.Dim, { AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -106, 0.5, 0) })
        local function small(text, x, fn)
            local b = UI.new("TextButton", { AutoButtonColor = false, AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, x, 0.5, 0),
                Size = UDim2.fromOffset(26, 26), BackgroundColor3 = TH.Elevated, Text = text, TextSize = 13, Font = TH.Bold,
                TextColor3 = TH.Sub, Parent = f }, { UI.corner(7) })
            UI.press(b)
            UI.track(b.Activated:Connect(fn))
        end
        small("▲", -72, function()
            UI.moveInOrder(i, -1)
        end)
        small("▼", -42, function()
            UI.moveInOrder(i, 1)
        end)
        small("×", -12, function()
            local list = table.clone(CFG.Chain.Order)
            table.remove(list, i)
            G.order = list
            CFG.Chain.Order = list
            UI.save()
            UI.rebuildChainRows()
        end)
        UI.chainRows[i] = { name = name, frame = f, stroke = st, avatar = av, info = info, pill = pill }
        UI.avatarFor(av, name, TH.Stroke, function(uid)
            if not f.Parent then
                return
            end
            if uid then
                info.Text = "ID " .. uid
            else
                info.Text = "account not found"
                info.TextColor3 = TH.Bad
            end
        end)
    end
    UI.chainAt = 0
end

function UI.refreshChain()
    local el = UI.el
    local order = CFG.Chain.Order
    local bi = S.chain.builderIdx
    local done = 0
    for i, r in ipairs(UI.chainRows) do
        local st = CH.read(r.name)
        local isMe = string.lower(r.name) == string.lower(LP.Name)
        local label, color
        if st and st.phase == "done" then
            label, color = "DONE", TH.Good
            done = done + 1
        elseif not CH.fresh(st) and not isMe then
            label, color = "OFFLINE", TH.Dim
        elseif i == bi then
            label, color = (st and st.phase == "send") and "SENDING" or "BUILDING", TH.Accent
        elseif st and st.phase == "host" then
            label, color = "RECEIVING", TH.Warn
        else
            label, color = "QUEUE", TH.Sub
        end
        if r.pill.Text ~= label then
            r.pill.Text = label
            r.pill.TextColor3 = color
            r.pill.BackgroundColor3 = color
            UI.tween(r.stroke, MOTION.Base, { Color = color:Lerp(TH.Stroke, 0.55) })
            r.avatar.ring.Color = color
        end
        r.frame.BackgroundColor3 = isMe and TH.Elevated or TH.Panel
    end
    el.chainHead.Text = #order == 0 and "No accounts yet - paste names above"
        or (#order .. " accounts · " .. done .. " done" .. (bi and ("  ·  building: #" .. bi .. " " .. tostring(order[bi])) or ""))
end

function UI.potionList()
    if UI.potions then
        return UI.potions
    end
    local roman = { "I", "II", "III", "IV", "V" }
    local list = {}
    for name, cfg in pairs(M.Entry.entriesOfKind("Boost")) do
        table.insert(list, { name = name, cfg = cfg, category = tostring(cfg.category or ""), tier = cfg.tier or 0,
            tierName = roman[cfg.tier or 0] or tostring(cfg.tier) })
    end
    table.sort(list, function(a, b)
        if a.category ~= b.category then
            return a.category < b.category
        end
        return a.tier < b.tier
    end)
    UI.potions = list
    return list
end

-- ── Farm page ───────────────────────────────────────────────
function UI.buildFarm(page)
    local el = UI.el
    UI.new("UIListLayout", { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder, Parent = page })
    UI.section(page, "Running on this screen", 1)
    el.tFarm = UI.toggle(page, "Farm (roll · collect · buy · rebirth · sell)", function()
        return S.farm
    end, function(v)
        S.farm = v
    end, 2)
    el.tChain = UI.toggle(page, "Chain build (trade units to the next account)", function()
        return S.chainOn
    end, function(v)
        S.chainOn = v
    end, 3)
    el.tLevel = UI.toggle(page, "Level up placed units (pays back within 10 min)", function()
        return CFG.Farm.LevelUnits
    end, function(v)
        CFG.Farm.LevelUnits = v
    end, 4)
    el.tItems = UI.toggle(page, "Auto items (potions picked in the Potions tab + Lucky Spin)", function()
        return CFG.Farm.AutoItems
    end, function(v)
        CFG.Farm.AutoItems = v
    end, 5)
    UI.section(page, "Selling (shared by every screen)", 6)
    local sellRow = UI.new("Frame", { BackgroundColor3 = TH.Panel, Size = UDim2.new(1, 0, 0, 44), LayoutOrder = 7, Parent = page },
        { UI.corner(8), UI.stroke() })
    UI.label("Keep units earning at least  (0 = sell all not placed · e.g. 1qd, 5t, 1e15)", 12, TH.Text, TH.Font,
        { Position = UDim2.fromOffset(12, 0), Size = UDim2.new(1, -150, 1, 0), Parent = sellRow })
    el.keepBox = UI.new("TextBox", { AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -10, 0.5, 0), Size = UDim2.fromOffset(120, 28),
        BackgroundColor3 = TH.Bg, Text = "", TextSize = 13, Font = TH.Bold, TextColor3 = TH.Text, ClearTextOnFocus = true, Parent = sellRow },
        { UI.corner(6) })
    UI.track(el.keepBox.FocusLost:Connect(function()
        local txt = string.lower((string.gsub(el.keepBox.Text, "%s", "")))
        local n = tonumber(txt)
        if not n then
            local ok, v = pcall(M.NF.ParseCompact, txt)
            n = ok and v or nil
        end
        if n and n >= 0 then
            CFG.Sell.KeepIncomeAbove = n
            G.keepIncome = n
            UI.save()
            UI.toast(n > 0 and ("Keeping units ≥ $" .. H.fmt(n) .. "/s") or "Selling every unit not placed", "Good")
        else
            UI.toast("not a number - use 1qd, 5t or 1e15", "Bad")
        end
        UI.paintFarm()
    end))
    local freeRow = UI.new("Frame", { BackgroundColor3 = TH.Panel, Size = UDim2.new(1, 0, 0, 44), LayoutOrder = 8, Parent = page },
        { UI.corner(8), UI.stroke() })
    UI.label("Sell when free inventory slots drop below", 12, TH.Text, TH.Font,
        { Position = UDim2.fromOffset(12, 5), Size = UDim2.new(1, -190, 0, 18), Parent = freeRow })
    el.freeInfo = UI.label("", 11, TH.Sub, TH.Font, { Position = UDim2.fromOffset(12, 22), Size = UDim2.new(1, -190, 0, 16), Parent = freeRow })
    local function setFree(n)
        n = math.clamp(math.floor(n), 1, 500)
        CFG.Sell.FreeSlots = n
        G.freeSlots = n
        UI.save()
        UI.paintFarm()
    end
    local function step(text, x, delta)
        local b = UI.new("TextButton", { AutoButtonColor = false, AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, x, 0.5, 0),
            Size = UDim2.fromOffset(28, 28), BackgroundColor3 = TH.Accent, Text = text, TextSize = 15, Font = TH.Bold,
            TextColor3 = TH.Text, Parent = freeRow }, { UI.corner() })
        UI.press(b)
        UI.track(b.Activated:Connect(function()
            setFree(CFG.Sell.FreeSlots + delta)
        end))
    end
    step("+", -10, 5)
    el.freeBox = UI.new("TextBox", { AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -44, 0.5, 0), Size = UDim2.fromOffset(90, 28),
        BackgroundColor3 = TH.Bg, Text = "", TextSize = 13, Font = TH.Bold, TextColor3 = TH.Text, ClearTextOnFocus = true, Parent = freeRow },
        { UI.corner(6) })
    step("–", -140, -5)
    UI.track(el.freeBox.FocusLost:Connect(function()
        local n = tonumber((string.gsub(el.freeBox.Text, "%D", "")))
        if n then
            setFree(n)
            UI.toast("selling when fewer than " .. CFG.Sell.FreeSlots .. " slots are free", "Good")
        else
            UI.paintFarm()
        end
    end))
    local actions = UI.new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 40), LayoutOrder = 9, Parent = page })
    UI.button(actions, "Sell overflow now", TH.Accent, { Size = UDim2.new(0.5, -4, 1, 0) }, function()
        SYS.sell(true)
        UI.toast(S.lastSell ~= "" and S.lastSell or "nothing to sell", "Good")
    end)
    UI.button(actions, "Re-redeem codes", TH.Panel, { AnchorPoint = Vector2.new(1, 0), Position = UDim2.fromScale(1, 0),
        Size = UDim2.new(0.5, -4, 1, 0) }, function()
        S.codesDone = false
        SYS.rewards()
        UI.toast("codes sent", "Good")
    end)
    UI.paintFarm()
end

function UI.paintFarm()
    local el = UI.el
    if not el.keepBox then
        return
    end
    local v = tonumber(CFG.Sell.KeepIncomeAbove) or 0
    if not el.keepBox:IsFocused() then
        el.keepBox.Text = v > 0 and H.fmt(v) or "0"
    end
    local _, cap, free = H.storage()
    if not el.freeBox:IsFocused() then
        el.freeBox.Text = tostring(CFG.Sell.FreeSlots)
    end
    local rolls = H.buff("Rolls")
    el.freeInfo.Text = "now " .. free .. " / " .. cap .. " free" .. (rolls > CFG.Sell.FreeSlots and
        (" · never below " .. rolls .. " (dice rolled per click)") or "")
    el.freeInfo.TextColor3 = free < math.max(CFG.Sell.FreeSlots, rolls) and TH.Warn or TH.Sub
end

-- ── live updates ────────────────────────────────────────────


function UI.frame(dt)
    if not UI.gui or not UI.gui.Parent then
        UI.destroy()
        return
    end
    local el = UI.el
    local ph = PHASES[UI.phase or "FARM"] or PHASES.FARM
    local t = os.clock()
    local wave = (t * ph.pulse) % 1
    el.ringScale.Scale = 1 + wave * 0.3
    el.ringStroke.Transparency = wave
    for i, d in ipairs(el.flow) do
        local p = (t * 0.7 + i / #el.flow) % 1
        d.Position = UDim2.fromScale(p, 0.5)
        d.BackgroundTransparency = 1 - math.sin(p * math.pi)
    end
    el.heroGlow.Rotation = (el.heroGlow.Rotation + 25 * dt) % 360
    el.sweep.Rotation = (el.sweep.Rotation + ph.sweep * dt) % 360
    if UI.activeNode then
        UI.activeNode.scale.Scale = 1 + math.sin(t * 4) * 0.12
    end
    UI.deliverIcons()
    local tab = UI.tab and UI.tab.name
    if tab == "Tower" then
        UI.animTower(t)
    end
    if tab == "Goal" and UI.diceBuild then
        pcall(UI.buildDiceCards)
    end
    if t >= UI.refreshAt then
        UI.refreshAt = t + 0.5
        local ok, err = pcall(function()
            UI.refreshStatus()
            if (UI.goalAt or 0) < t then
                UI.goalAt = t + 3
                if GL.load() then
                    log("settings updated from another screen")
                    UI.unitsDirty = true
                    if #UI.chainRows ~= #CFG.Chain.Order then
                        UI.rebuildChainRows()
                    end
                end
                if tab == "Goal" then
                    UI.paintGoal()
                elseif tab == "Skill Tree" then
                    UI.paintTree()
                elseif tab == "Potions" then
                    UI.paintPotions()
                elseif tab == "Tower" then
                    UI.paintTower(true)
                elseif tab == "Farm" then
                    UI.paintFarm()
                    for _, k in ipairs({ "tFarm", "tChain", "tLevel", "tItems" }) do
                        el[k].paint()
                    end
                end
            end
            if tab == "Skill Tree" and not UI.treeBuilt then
                UI.buildTreeTiles()
            end
            if tab == "Units" and (UI.unitsDirty or (UI.unitsAt or 0) < t) then
                UI.unitsAt = t + 5
                UI.renderUnits()
            end
            if tab == "Chain" and (UI.chainAt or 0) < t then
                UI.chainAt = t + 2
                UI.refreshChain()
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


-- what this account is doing right now, in one readable line for the account manager:
--   Build (Dice Genesis → Skeleton)      still building; lists only what the Goal tab needs
--   Waiting for Trade → <next>           maxed, waiting for the next account to arrive / trade
--   Trading with <name>                   trade window is open
--   Success! sent to <next>               finished (sent once by CH.afterDone, then Done)
--   Queue #4 · builder <name>             waiting for its turn
--   Joining <name> / Waiting for Trade ← <name>   it is our turn to receive
--   Farming                               not in Chain.Order (or chain off)
function UI.activity()
    local ch = S.chain
    if not S.chainOn or not ch.myIndex then
        return "Farming"
    end
    if ch.role == "builder" then
        if ch.phase == "send" then
            if T.active then
                return "Trading with " .. tostring(ch.target)
            end
            return "Waiting for Trade → " .. tostring(ch.target)
        end
        local parts = {}
        if G.needDice then
            table.insert(parts, "Dice " .. tostring(D.Dice()) .. " → " .. tostring(G.dice))
        end
        if G.needRebirth then
            table.insert(parts, "Rebirth " .. D.Rebirth() .. "/" .. G.rebirth)
        end
        if G.needUpgrades then
            table.insert(parts, "Upgrades " .. H.upgradesOwned() .. "/" .. S.upgradeTotal)
        end
        return "Build (" .. table.concat(parts, ", ") .. ")"
    end
    if ch.phase == "host" then
        if T.active then
            return "Trading with " .. tostring(ch.target)
        end
        if ch.builderHere then
            return "Waiting for Trade ← " .. tostring(ch.target)
        end
        return "Joining " .. tostring(ch.target)
    end
    return "Queue #" .. tostring(ch.myIndex) .. " · builder " .. tostring(ch.builderName or "?")
end

function UI.manager()
    if S.chain.done then
        return
    end
    local desc = UI.activity()
    MGR.status(desc, {
        __order = { "Rebirth", "Dice", "Upgrades", "Money", "Phase" },
        Rebirth = D.Rebirth() .. "/" .. S.rebirthTarget,
        Dice = tostring(D.Dice()),
        Upgrades = H.upgradesOwned() .. "/" .. S.upgradeTotal,
        Money = H.fmt(D.Money()),
        Phase = desc,
    })
end

-- ════════════════════════════════════════════════════════════
-- START
-- ════════════════════════════════════════════════════════════
log(string.format("loaded · %s · rebirth %d/%d · top dice %s · %d upgrades · PlaceId %d",
    LP.Name, D.Rebirth(), S.rebirthTarget, tostring(S.topDice), S.upgradeTotal, game.PlaceId))
if S.keepParseError then
    log("KeepIncomeAbove \"" .. S.keepParseError .. "\" unreadable - keeping all units (use e.g. \"10qd\" or 1e16)", "Bad")
elseif CFG.Sell.KeepIncomeAbove > 0 then
    log("sell: keeping units at or above $" .. H.fmt(CFG.Sell.KeepIncomeAbove) .. "/s")
else
    log("sell: selling every unit that is not plotted")
end
if game.PrivateServerId ~= "" then
    log("private server: trading is disabled here by the game", "Warn")
end
do
    local ok, err = H.queueReexec()
    S.rejoin = ok and "auto re-run queued" or ("NOT queued: " .. tostring(err) .. " - put Loader.lua in autoexec")
    log("teleport re-run: " .. S.rejoin, ok and "Good" or "Bad")
end
SYS.graphics(CFG.Farm.Graphics)
task.spawn(SYS.antiAfk)
task.spawn(SYS.rollLoop)
task.spawn(SYS.economyLoop)
task.spawn(SYS.towerLoop)
task.spawn(SYS.slowLoop)
task.spawn(CH.loop)
if GL.load() then
    log("settings loaded from " .. GL.path)
end
if M.EntryIcon then
    task.spawn(ICON.workerLoop)
end
do
    local ok, err = pcall(UI.build)
    if not ok then
        log("ui build error: " .. tostring(err), "Bad")
    end
end
task.spawn(function()
    while alive() do
        pcall(UI.manager)
        task.wait(10)
    end
    UI.destroy()
end)
UI.toast("Anime Dice loaded · RightCtrl hides", "Good")
