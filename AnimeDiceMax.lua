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
        lastTp = 0, lastHop = 0, lastHostCheck = 0 },
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
end
local D = M.Data

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
    for _, u in ipairs(units) do
        if not plotted[u.key] and not keep[u.key] and not u.attrs.locked then
            if threshold <= 0 or u.income < threshold then
                table.insert(list, u.key)
            end
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

-- "maxed" = every condition in Chain.MaxedWhen holds
function SYS.maxed()
    local need = H.set(CFG.Chain.MaxedWhen)
    local res = { ok = true, parts = {} }
    if need.Rebirth then
        local okR = D.Rebirth() >= S.rebirthTarget
        res.ok = res.ok and okR
        table.insert(res.parts, "Rebirth " .. D.Rebirth() .. "/" .. S.rebirthTarget .. (okR and " ok" or ""))
    end
    if need.Dice then
        local okD = S.topDice ~= nil and (D.OwnedDice() or {})[S.topDice] == true
        res.ok = res.ok and okD
        table.insert(res.parts, "Dice " .. tostring(S.topDice) .. (okD and " ok" or " no"))
    end
    if need.Upgrades then
        local owned = H.upgradesOwned()
        local okU = owned >= S.upgradeTotal
        local giveUp = tonumber(CFG.Chain.UpgradeGiveUpMin) or 0
        if not okU and giveUp > 0 and os.time() - S.lastUpgradeBuy >= giveUp * 60 then
            -- stalled for N minutes: maxed if every remaining upgrade costs more than we hold
            local money = D.Money()
            local ownedT = D.Upgrades() or {}
            local affordable = false
            for name, u in pairs(M.Upgrades) do
                if name ~= "Start" and not ownedT[name] and (u.price or 0) <= money then
                    affordable = true
                    break
                end
            end
            okU = not affordable
        end
        res.ok = res.ok and okU
        table.insert(res.parts, "Upgrades " .. owned .. "/" .. S.upgradeTotal .. (okU and " ok" or ""))
    end
    res.text = table.concat(res.parts, " · ")
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
                table.insert(queue, { key = key, amount = e.amount, tier = cfg.tier or 0 })
            elseif cfg.kind == "Spin" and e.name ~= "Jackpot Spin" then
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
local MGR = { storm = nil, stormTried = false, lastName = "?" }

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
        if MGR.fn("Masterp_Description") then
            pcall(MGR.fn("Masterp_Description"), text)
        end
        if MGR.fn("Masterp_Done") then
            pcall(MGR.fn("Masterp_Done"))
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

function CH.finish(why)
    S.chain.done = true
    S.chain.phase = "done"
    S.chain.msg = "DONE · " .. why
    CH.write()
    log("chain done: " .. why, "Good")
    local closesItself = MGR.done("DONE " .. why)
    if CFG.Chain.LeaveWhenDone then
        -- give a manager that closes Roblox by itself time to record "done" first
        task.wait(closesItself and 20 or 5)
        H.leave("chain done")
    end
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
            local free = (st.maxPlayers or 0) - (st.players or 0)
            if st.public and free >= CFG.Trade.FreeSlots + 1 then
                if os.time() - S.chain.lastTp > 30 then
                    S.chain.msg = "joining " .. targetName .. "'s server"
                    H.teleport(st.jobId)
                end
            else
                S.chain.msg = "waiting: " .. targetName .. "'s server " .. (st.public and ("has " .. free .. " free") or "is private")
            end
            return
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
    -- stop rolling once the builder is here so storage stays free for the units
    S.pauseRoll = builderHere
    local _, _, free = H.storage()
    if free < math.max(CFG.Sell.FreeSlots, 6) and not T.active then
        SYS.sell(true)
    end
    if not builderHere then
        local slots = Players.MaxPlayers - #Players:GetPlayers()
        local public = game.PrivateServerId == ""
        if (not public or slots < CFG.Trade.FreeSlots + 1) and CFG.Trade.HostHop
            and os.time() - S.chain.lastHop > K.HOP_COOLDOWN then
            S.chain.lastHop = os.time()
            local id = H.findServer(CFG.Trade.FreeSlots + 2)
            if id then
                S.chain.msg = "hopping to a roomier public server"
                H.teleport(id)
                return
            end
        end
        S.chain.msg = "hosting · waiting for " .. builderName .. " to join"
        return
    end
    S.chain.msg = "hosting · " .. builderName .. " is here" .. (T.active and (" · trade " .. tostring(T.phase)) or "")
end

function CH.loop()
    while alive() and not S.chainOn do
        S.chain.msg = "off"
        task.wait(1)
    end
    local me = nil
    for i, name in ipairs(CFG.Chain.Order) do
        if string.lower(name) == string.lower(LP.Name) then
            me = i
        end
    end
    S.chain.myIndex = me
    if not me then
        S.chain.msg = LP.Name .. " is not in Chain.Order - farming only"
        log(S.chain.msg, "Warn")
        return
    end
    local prev = CH.read(LP.Name)
    if prev and prev.phase == "done" then
        S.chain.done = true
        S.chain.phase = "done"
        S.chain.msg = "already DONE (delete " .. chainFile(LP.Name) .. " to rebuild)"
        log(S.chain.msg, "Good")
        local closesItself = MGR.done("DONE (already)")
        if CFG.Chain.LeaveWhenDone then
            task.wait(closesItself and 20 or 5)
            H.leave("chain already done")
        end
        return
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
    while alive() do
        if S.chainOn then
            if T.justReceived then
                T.justReceived = false
                log("received the chain items", "Good")
                pcall(CH.afterReceive)
            end
            local ok, err = pcall(CH.tick)
            if not ok then
                log("chain error: " .. tostring(err), "Bad")
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
        else
            S.chain.msg = "off"
            task.wait(2)
        end
    end
end

-- ════════════════════════════════════════════════════════════
-- UI (UIFX kit, inlined)
-- ════════════════════════════════════════════════════════════
local UIFX = (function()
-- UIFX: dark-minimal UI kit for executor scripts (plain untyped Luau)
-- Usage (inline, single-file scripts):
--   local UIFX = (function() <paste this file> end)()
-- Usage (local file in executor workspace):
--   local UIFX = loadstring(readfile("UIFX.lua"))()

local UIFX = {}

local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

-- Design tokens. Change colors here, never inline in elements.
UIFX.Theme = {
    Bg = Color3.fromRGB(16, 16, 20),
    Panel = Color3.fromRGB(23, 23, 29),
    Elevated = Color3.fromRGB(31, 31, 39),
    Stroke = Color3.fromRGB(46, 46, 56),
    Text = Color3.fromRGB(236, 236, 242),
    SubText = Color3.fromRGB(148, 148, 162),
    Accent = Color3.fromRGB(108, 138, 255),
    Good = Color3.fromRGB(78, 196, 120),
    Warn = Color3.fromRGB(238, 178, 68),
    Bad = Color3.fromRGB(232, 82, 92),
    Font = Enum.Font.GothamMedium,
    FontBold = Enum.Font.GothamBold,
    Radius = 8,
}

-- Motion tokens. Fast = hover/press, Base = state change, Slow = open/close.
UIFX.Motion = {
    Fast = TweenInfo.new(0.12, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
    Base = TweenInfo.new(0.22, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
    Slow = TweenInfo.new(0.38, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
    Spring = TweenInfo.new(0.42, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
}

local Theme = UIFX.Theme
local Motion = UIFX.Motion

-- ── primitives ──────────────────────────────────────────────

local function new(class, props, children)
    local inst = Instance.new(class)
    local parent = nil
    for k, v in pairs(props or {}) do
        if k == "Parent" then
            parent = v
        else
            inst[k] = v
        end
    end
    for _, child in ipairs(children or {}) do
        child.Parent = inst
    end
    if parent then
        inst.Parent = parent
    end
    return inst
end
UIFX.new = new

local function tween(inst, info, goal)
    local t = TweenService:Create(inst, info, goal)
    t:Play()
    return t
end
UIFX.tween = tween

local function corner(radius)
    return new("UICorner", { CornerRadius = UDim.new(0, radius or Theme.Radius) })
end

local function stroke(color, transparency)
    return new("UIStroke", {
        Color = color or Theme.Stroke,
        Transparency = transparency or 0,
        Thickness = 1,
        ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
    })
end

local function padding(px)
    return new("UIPadding", {
        PaddingTop = UDim.new(0, px),
        PaddingBottom = UDim.new(0, px),
        PaddingLeft = UDim.new(0, px),
        PaddingRight = UDim.new(0, px),
    })
end

local function label(text, size, color, font)
    return new("TextLabel", {
        BackgroundTransparency = 1,
        Text = text,
        TextSize = size or 13,
        TextColor3 = color or Theme.Text,
        Font = font or Theme.Font,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Center,
        Size = UDim2.new(1, 0, 1, 0),
    })
end

local function isPointer(input)
    return input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch
end

local function isMove(input)
    return input.UserInputType == Enum.UserInputType.MouseMovement
        or input.UserInputType == Enum.UserInputType.Touch
end

-- Hidden parent first: gethui() is unreachable from game scripts.
local function guiParent()
    if type(gethui) == "function" then
        local ok, hui = pcall(gethui)
        if ok and hui then
            return hui
        end
    end
    local ok, core = pcall(function()
        return game:GetService("CoreGui")
    end)
    if ok and core then
        return core
    end
    return Players.LocalPlayer:WaitForChild("PlayerGui")
end

-- Ink ripple from the pointer position. Button needs ClipsDescendants = true.
local function ripple(button)
    local mouse = UserInputService:GetMouseLocation()
    local abs = button.AbsolutePosition
    local size = math.max(button.AbsoluteSize.X, button.AbsoluteSize.Y) * 2.2
    local dot = new("Frame", {
        BackgroundColor3 = Theme.Text,
        BackgroundTransparency = 0.86,
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.fromOffset(mouse.X - abs.X, mouse.Y - abs.Y),
        Size = UDim2.fromOffset(0, 0),
        ZIndex = button.ZIndex + 1,
        Parent = button,
    }, { corner(9999) })
    tween(dot, TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
        Size = UDim2.fromOffset(size, size),
        BackgroundTransparency = 1,
    })
    task.delay(0.55, function()
        dot:Destroy()
    end)
end
UIFX.ripple = ripple

-- ── window ──────────────────────────────────────────────────

function UIFX.Window(opts)
    opts = opts or {}
    local title = opts.Title or "Script"
    local size = opts.Size or UDim2.fromOffset(520, 340)
    local toggleKey = opts.ToggleKey or Enum.KeyCode.RightControl
    local guiName = "UIFX_" .. title

    local win = { Alive = true, Tabs = {} }
    local conns = {}
    local statuses = {}

    local function track(conn)
        table.insert(conns, conn)
        return conn
    end
    win.track = track

    -- Single instance: a re-run removes the old window; the old copy's
    -- watchdog sees its gui lose its Parent and shuts itself down.
    local parent = guiParent()
    local old = parent:FindFirstChild(guiName)
    if old then
        old:Destroy()
    end

    local gui = new("ScreenGui", {
        Name = guiName,
        ResetOnSpawn = false,
        IgnoreGuiInset = true,
        ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
        DisplayOrder = 999,
    })
    gui.Parent = parent
    win.Gui = gui

    local root = new("CanvasGroup", {
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.fromScale(0.5, 0.5),
        Size = size,
        BackgroundColor3 = Theme.Bg,
        GroupTransparency = 1,
        Parent = gui,
    }, { corner(Theme.Radius + 2), stroke(Theme.Stroke) })
    local scale = new("UIScale", { Scale = 0.94, Parent = root })
    win.Root = root

    -- top bar
    local topbar = new("Frame", {
        BackgroundTransparency = 1,
        Size = UDim2.new(1, 0, 0, 38),
        Parent = root,
    })
    local titleLabel = label(title, 14, Theme.Text, Theme.FontBold)
    titleLabel.Position = UDim2.fromOffset(14, 0)
    titleLabel.Size = UDim2.new(1, -100, 1, 0)
    titleLabel.Parent = topbar
    new("Frame", {
        BackgroundColor3 = Theme.Stroke,
        BorderSizePixel = 0,
        Position = UDim2.new(0, 0, 1, -1),
        Size = UDim2.new(1, 0, 0, 1),
        Parent = topbar,
    })

    local function topButton(text, xOffset, hoverColor)
        local b = new("TextButton", {
            AutoButtonColor = false,
            AnchorPoint = Vector2.new(1, 0.5),
            Position = UDim2.new(1, xOffset, 0.5, 0),
            Size = UDim2.fromOffset(26, 26),
            BackgroundColor3 = Theme.Elevated,
            BackgroundTransparency = 1,
            Text = text,
            TextSize = 16,
            TextColor3 = Theme.SubText,
            Font = Theme.FontBold,
            Parent = topbar,
        }, { corner(6) })
        track(b.MouseEnter:Connect(function()
            tween(b, Motion.Fast, { BackgroundTransparency = 0, TextColor3 = hoverColor })
        end))
        track(b.MouseLeave:Connect(function()
            tween(b, Motion.Fast, { BackgroundTransparency = 1, TextColor3 = Theme.SubText })
        end))
        return b
    end
    local closeBtn = topButton("×", -8, Theme.Bad)
    local minBtn = topButton("–", -38, Theme.Text)

    -- smooth drag by the top bar
    do
        local dragging = false
        local startMouse, startPos
        track(topbar.InputBegan:Connect(function(input)
            if isPointer(input) then
                dragging = true
                startMouse = input.Position
                startPos = root.Position
            end
        end))
        track(UserInputService.InputEnded:Connect(function(input)
            if isPointer(input) then
                dragging = false
            end
        end))
        track(UserInputService.InputChanged:Connect(function(input)
            if dragging and isMove(input) then
                local d = input.Position - startMouse
                tween(root, Motion.Fast, {
                    Position = UDim2.new(
                        startPos.X.Scale, startPos.X.Offset + d.X,
                        startPos.Y.Scale, startPos.Y.Offset + d.Y
                    ),
                })
            end
        end))
    end

    -- sidebar + pages
    local sidebar = new("Frame", {
        BackgroundColor3 = Theme.Panel,
        BorderSizePixel = 0,
        Position = UDim2.fromOffset(0, 38),
        Size = UDim2.new(0, 132, 1, -38),
        Parent = root,
    })
    new("UIListLayout", {
        Padding = UDim.new(0, 4),
        SortOrder = Enum.SortOrder.LayoutOrder,
        Parent = sidebar,
    })
    new("UIPadding", {
        PaddingTop = UDim.new(0, 8),
        PaddingLeft = UDim.new(0, 8),
        PaddingRight = UDim.new(0, 8),
        Parent = sidebar,
    })
    local indicator = new("Frame", {
        BackgroundColor3 = Theme.Accent,
        BorderSizePixel = 0,
        Size = UDim2.fromOffset(3, 18),
        Position = UDim2.fromOffset(2, 14),
        Visible = false,
        Parent = root,
    }, { corner(2) })

    local pages = new("Frame", {
        BackgroundTransparency = 1,
        Position = UDim2.fromOffset(132, 38),
        Size = UDim2.new(1, -132, 1, -38),
        Parent = root,
    })

    -- open / close / minimize
    local visible = false
    local minimized = false

    function win:Show()
        visible = true
        gui.Enabled = true
        tween(root, Motion.Slow, { GroupTransparency = 0 })
        tween(scale, Motion.Spring, { Scale = 1 })
    end

    function win:Hide()
        visible = false
        tween(root, Motion.Base, { GroupTransparency = 1 })
        local t = tween(scale, Motion.Base, { Scale = 0.94 })
        t.Completed:Connect(function()
            if not visible and win.Alive then
                gui.Enabled = false
            end
        end)
    end

    function win:Toggle()
        if visible then
            win:Hide()
        else
            win:Show()
        end
    end

    function win:Destroy()
        if not win.Alive then
            return
        end
        win.Alive = false
        for _, c in ipairs(conns) do
            c:Disconnect()
        end
        table.clear(conns)
        if opts.OnClose then
            task.spawn(opts.OnClose)
        end
        local t = tween(root, Motion.Base, { GroupTransparency = 1 })
        tween(scale, Motion.Base, { Scale = 0.9 })
        t.Completed:Connect(function()
            gui:Destroy()
        end)
    end

    track(closeBtn.MouseButton1Click:Connect(function()
        win:Destroy()
    end))
    track(minBtn.MouseButton1Click:Connect(function()
        minimized = not minimized
        if minimized then
            tween(root, Motion.Base, { Size = UDim2.new(size.X.Scale, size.X.Offset, 0, 38) })
        else
            tween(root, Motion.Spring, { Size = size })
        end
    end))
    track(UserInputService.InputBegan:Connect(function(input, processed)
        if not processed and input.KeyCode == toggleKey then
            win:Toggle()
        end
    end))

    -- One thread owns every text write coming from outside (game callbacks
    -- that touch protected gui can fail with "lacking capability").
    track(RunService.Heartbeat:Connect(function()
        if not gui.Parent then
            win:Destroy()
            return
        end
        for _, s in ipairs(statuses) do
            if s.dirty then
                s.dirty = false
                s.body.Text = s.text
                s.body.TextColor3 = s.color
            end
        end
    end))

    -- ── notifications ──
    local toastHolder = new("Frame", {
        BackgroundTransparency = 1,
        AnchorPoint = Vector2.new(1, 1),
        Position = UDim2.new(1, -16, 1, -16),
        Size = UDim2.fromOffset(280, 400),
        Parent = gui,
    })
    new("UIListLayout", {
        Padding = UDim.new(0, 8),
        VerticalAlignment = Enum.VerticalAlignment.Bottom,
        SortOrder = Enum.SortOrder.LayoutOrder,
        Parent = toastHolder,
    })
    local toastCount = 0

    function win:Notify(text, kind, duration)
        duration = duration or 3
        local color = Theme[kind or "Accent"] or Theme.Accent
        toastCount = toastCount + 1
        local slot = new("Frame", {
            BackgroundTransparency = 1,
            Size = UDim2.new(1, 0, 0, 0),
            LayoutOrder = toastCount,
            ClipsDescendants = false,
            Parent = toastHolder,
        })
        local card = new("Frame", {
            BackgroundColor3 = Theme.Panel,
            Position = UDim2.fromOffset(300, 0),
            Size = UDim2.new(1, 0, 1, 0),
            Parent = slot,
        }, { corner(), stroke(Theme.Stroke) })
        new("Frame", {
            BackgroundColor3 = color,
            BorderSizePixel = 0,
            Position = UDim2.fromOffset(0, 8),
            Size = UDim2.new(0, 3, 1, -16),
            Parent = card,
        }, { corner(2) })
        local msg = label(text, 13, Theme.Text)
        msg.TextWrapped = true
        msg.Position = UDim2.fromOffset(14, 0)
        msg.Size = UDim2.new(1, -24, 1, -4)
        msg.Parent = card
        local bar = new("Frame", {
            BackgroundColor3 = color,
            BackgroundTransparency = 0.4,
            BorderSizePixel = 0,
            AnchorPoint = Vector2.new(0, 1),
            Position = UDim2.new(0, 0, 1, 0),
            Size = UDim2.new(1, 0, 0, 2),
            Parent = card,
        })
        tween(slot, Motion.Base, { Size = UDim2.new(1, 0, 0, 52) })
        tween(card, Motion.Spring, { Position = UDim2.fromOffset(0, 0) })
        tween(bar, TweenInfo.new(duration, Enum.EasingStyle.Linear), { Size = UDim2.new(0, 0, 0, 2) })
        task.delay(duration, function()
            local t = tween(card, Motion.Base, { Position = UDim2.fromOffset(300, 0) })
            t.Completed:Wait()
            local s = tween(slot, Motion.Base, { Size = UDim2.new(1, 0, 0, 0) })
            s.Completed:Wait()
            slot:Destroy()
        end)
    end

    -- Run a user callback; surface errors instead of swallowing them.
    local function run(fn, ...)
        if not fn then
            return
        end
        local args = table.pack(...)
        task.spawn(function()
            local ok, err = pcall(fn, table.unpack(args, 1, args.n))
            if not ok then
                print("[UIFX] callback error: " .. tostring(err))
                win:Notify(tostring(err), "Bad", 5)
            end
        end)
    end

    -- ── tabs ──
    local function selectTab(tab)
        for _, t in ipairs(win.Tabs) do
            local on = t == tab
            t.Page.Visible = on
            tween(t.TabButton, Motion.Fast, {
                BackgroundTransparency = on and 0 or 1,
                TextColor3 = on and Theme.Text or Theme.SubText,
            })
        end
        indicator.Visible = true
        local y = tab.TabButton.AbsolutePosition.Y - root.AbsolutePosition.Y
        tween(indicator, Motion.Spring, {
            Position = UDim2.fromOffset(10, y / scale.Scale + 7),
        })
        tab.Page.Position = UDim2.fromOffset(0, 8)
        tween(tab.Page, Motion.Base, { Position = UDim2.fromOffset(0, 0) })
    end

    function win:Tab(name)
        local tab = {}
        tab.TabButton = new("TextButton", {
            AutoButtonColor = false,
            BackgroundColor3 = Theme.Elevated,
            BackgroundTransparency = 1,
            Size = UDim2.new(1, 0, 0, 32),
            Text = "      " .. name,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextSize = 13,
            TextColor3 = Theme.SubText,
            Font = Theme.Font,
            LayoutOrder = #win.Tabs + 1,
            Parent = sidebar,
        }, { corner(6) })
        tab.Page = new("ScrollingFrame", {
            BackgroundTransparency = 1,
            BorderSizePixel = 0,
            Size = UDim2.new(1, 0, 1, 0),
            CanvasSize = UDim2.new(),
            AutomaticCanvasSize = Enum.AutomaticSize.Y,
            ScrollBarThickness = 3,
            ScrollBarImageColor3 = Theme.Stroke,
            Visible = false,
            Parent = pages,
        }, { padding(10) })
        new("UIListLayout", {
            Padding = UDim.new(0, 6),
            SortOrder = Enum.SortOrder.LayoutOrder,
            Parent = tab.Page,
        })
        table.insert(win.Tabs, tab)
        local order = 0

        track(tab.TabButton.MouseButton1Click:Connect(function()
            selectTab(tab)
        end))

        local function row(height)
            order = order + 1
            return new("Frame", {
                BackgroundColor3 = Theme.Panel,
                Size = UDim2.new(1, 0, 0, height or 38),
                LayoutOrder = order,
                Parent = tab.Page,
            }, { corner(), stroke(Theme.Stroke, 0.3) })
        end

        local function hover(target)
            track(target.MouseEnter:Connect(function()
                tween(target, Motion.Fast, { BackgroundColor3 = Theme.Elevated })
            end))
            track(target.MouseLeave:Connect(function()
                tween(target, Motion.Fast, { BackgroundColor3 = Theme.Panel })
            end))
        end

        function tab:Section(text)
            order = order + 1
            local l = label(string.upper(text), 11, Theme.SubText, Theme.FontBold)
            l.Size = UDim2.new(1, 0, 0, 22)
            l.LayoutOrder = order
            l.Parent = tab.Page
            return l
        end

        function tab:Button(text, callback)
            order = order + 1
            local b = new("TextButton", {
                AutoButtonColor = false,
                ClipsDescendants = true,
                BackgroundColor3 = Theme.Panel,
                Size = UDim2.new(1, 0, 0, 38),
                Text = "",
                LayoutOrder = order,
                Parent = tab.Page,
            }, { corner(), stroke(Theme.Stroke, 0.3) })
            local l = label(text, 13)
            l.Position = UDim2.fromOffset(12, 0)
            l.Size = UDim2.new(1, -24, 1, 0)
            l.Parent = b
            hover(b)
            local busy = false
            local obj = {}
            track(b.MouseButton1Click:Connect(function()
                ripple(b)
                if busy then
                    return
                end
                run(callback)
            end))
            track(b.MouseButton1Down:Connect(function()
                tween(b, Motion.Fast, { BackgroundColor3 = Theme.Stroke })
            end))
            -- Lock while a long job runs: obj:SetBusy(true) ... obj:SetBusy(false)
            function obj:SetBusy(on)
                busy = on
                tween(l, Motion.Fast, { TextTransparency = on and 0.5 or 0 })
            end
            function obj:SetText(t)
                l.Text = t
            end
            return obj
        end

        function tab:Toggle(text, default, callback)
            local r = row(38)
            local l = label(text, 13)
            l.Position = UDim2.fromOffset(12, 0)
            l.Size = UDim2.new(1, -70, 1, 0)
            l.Parent = r
            local track_ = new("Frame", {
                AnchorPoint = Vector2.new(1, 0.5),
                Position = UDim2.new(1, -12, 0.5, 0),
                Size = UDim2.fromOffset(36, 20),
                BackgroundColor3 = Theme.Elevated,
                Parent = r,
            }, { corner(9999), stroke(Theme.Stroke) })
            local knob = new("Frame", {
                AnchorPoint = Vector2.new(0, 0.5),
                Position = UDim2.new(0, 3, 0.5, 0),
                Size = UDim2.fromOffset(14, 14),
                BackgroundColor3 = Theme.SubText,
                Parent = track_,
            }, { corner(9999) })
            local hit = new("TextButton", {
                BackgroundTransparency = 1,
                Size = UDim2.new(1, 0, 1, 0),
                Text = "",
                Parent = r,
            })
            hover(r)

            local obj = { Value = false }
            function obj:Set(v, silent)
                obj.Value = v and true or false
                tween(knob, Motion.Spring, {
                    Position = obj.Value and UDim2.new(1, -17, 0.5, 0) or UDim2.new(0, 3, 0.5, 0),
                    BackgroundColor3 = obj.Value and Theme.Text or Theme.SubText,
                })
                tween(track_, Motion.Base, {
                    BackgroundColor3 = obj.Value and Theme.Accent or Theme.Elevated,
                })
                if not silent then
                    run(callback, obj.Value)
                end
            end
            track(hit.MouseButton1Click:Connect(function()
                obj:Set(not obj.Value)
            end))
            obj:Set(default, true)
            if default then
                run(callback, true)
            end
            return obj
        end

        function tab:Slider(text, min, max, default, step, callback)
            step = step or 1
            local r = row(54)
            local l = label(text, 13)
            l.Position = UDim2.fromOffset(12, 6)
            l.Size = UDim2.new(1, -90, 0, 18)
            l.Parent = r
            local valueLabel = label("", 13, Theme.SubText)
            valueLabel.TextXAlignment = Enum.TextXAlignment.Right
            valueLabel.Position = UDim2.new(1, -82, 0, 6)
            valueLabel.Size = UDim2.fromOffset(70, 18)
            valueLabel.Parent = r
            local bar = new("Frame", {
                Position = UDim2.new(0, 12, 0, 34),
                Size = UDim2.new(1, -24, 0, 6),
                BackgroundColor3 = Theme.Elevated,
                Parent = r,
            }, { corner(9999) })
            local fill = new("Frame", {
                Size = UDim2.fromScale(0, 1),
                BackgroundColor3 = Theme.Accent,
                Parent = bar,
            }, { corner(9999) })
            local knob = new("Frame", {
                AnchorPoint = Vector2.new(0.5, 0.5),
                Position = UDim2.fromScale(0, 0.5),
                Size = UDim2.fromOffset(12, 12),
                BackgroundColor3 = Theme.Text,
                Parent = bar,
            }, { corner(9999) })

            local obj = { Value = default or min }
            local function render(instant)
                local a = (obj.Value - min) / (max - min)
                local info = instant and TweenInfo.new(0) or Motion.Fast
                tween(fill, info, { Size = UDim2.fromScale(a, 1) })
                tween(knob, info, { Position = UDim2.fromScale(a, 0.5) })
                valueLabel.Text = tostring(obj.Value)
            end
            function obj:Set(v, silent)
                v = math.clamp(v, min, max)
                v = min + math.floor((v - min) / step + 0.5) * step
                if v == obj.Value and not silent then
                    return
                end
                obj.Value = v
                render(false)
                if not silent then
                    run(callback, v)
                end
            end

            local dragging = false
            local function fromPointer()
                local x = UserInputService:GetMouseLocation().X
                local a = math.clamp((x - bar.AbsolutePosition.X) / bar.AbsoluteSize.X, 0, 1)
                obj:Set(min + (max - min) * a)
            end
            track(r.InputBegan:Connect(function(input)
                if isPointer(input) then
                    dragging = true
                    tween(knob, Motion.Fast, { Size = UDim2.fromOffset(16, 16) })
                    fromPointer()
                end
            end))
            track(UserInputService.InputEnded:Connect(function(input)
                if dragging and isPointer(input) then
                    dragging = false
                    tween(knob, Motion.Fast, { Size = UDim2.fromOffset(12, 12) })
                end
            end))
            track(UserInputService.InputChanged:Connect(function(input)
                if dragging and isMove(input) then
                    fromPointer()
                end
            end))
            render(true)
            return obj
        end

        function tab:Dropdown(text, options, default, callback)
            local r = row(38)
            r.ClipsDescendants = true
            local head = new("TextButton", {
                BackgroundTransparency = 1,
                Size = UDim2.new(1, 0, 0, 38),
                Text = "",
                Parent = r,
            })
            local l = label(text, 13)
            l.Position = UDim2.fromOffset(12, 0)
            l.Size = UDim2.new(0.5, -12, 1, 0)
            l.Parent = head
            local current = label("", 13, Theme.SubText)
            current.TextXAlignment = Enum.TextXAlignment.Right
            current.Position = UDim2.new(0.5, 0, 0, 0)
            current.Size = UDim2.new(0.5, -32, 1, 0)
            current.Parent = head
            local arrow = label("▾", 13, Theme.SubText)
            arrow.TextXAlignment = Enum.TextXAlignment.Center
            arrow.AnchorPoint = Vector2.new(1, 0)
            arrow.Position = UDim2.new(1, -8, 0, 0)
            arrow.Size = UDim2.fromOffset(18, 38)
            arrow.Parent = head
            local list = new("Frame", {
                BackgroundTransparency = 1,
                Position = UDim2.fromOffset(6, 40),
                Size = UDim2.new(1, -12, 0, 0),
                AutomaticSize = Enum.AutomaticSize.Y,
                Parent = r,
            })
            new("UIListLayout", { Padding = UDim.new(0, 2), Parent = list })

            local obj = { Value = default, Options = {} }
            local open = false
            local function setOpen(v)
                open = v
                local h = open and (44 + #obj.Options * 30) or 38
                tween(r, Motion.Base, { Size = UDim2.new(1, 0, 0, h) })
                tween(arrow, Motion.Base, { Rotation = open and 180 or 0 })
            end
            function obj:Set(v, silent)
                obj.Value = v
                current.Text = v and tostring(v) or "—"
                if not silent then
                    run(callback, v)
                end
            end
            function obj:Refresh(newOptions)
                obj.Options = newOptions
                list:ClearAllChildren()
                new("UIListLayout", { Padding = UDim.new(0, 2), Parent = list })
                for _, opt in ipairs(newOptions) do
                    local o = new("TextButton", {
                        AutoButtonColor = false,
                        BackgroundColor3 = Theme.Panel,
                        Size = UDim2.new(1, 0, 0, 28),
                        Text = "  " .. tostring(opt),
                        TextXAlignment = Enum.TextXAlignment.Left,
                        TextSize = 13,
                        TextColor3 = Theme.Text,
                        Font = Theme.Font,
                        Parent = list,
                    }, { corner(6) })
                    o.MouseEnter:Connect(function()
                        tween(o, Motion.Fast, { BackgroundColor3 = Theme.Elevated })
                    end)
                    o.MouseLeave:Connect(function()
                        tween(o, Motion.Fast, { BackgroundColor3 = Theme.Panel })
                    end)
                    o.MouseButton1Click:Connect(function()
                        obj:Set(opt)
                        setOpen(false)
                    end)
                end
                if open then
                    setOpen(true)
                end
            end
            track(head.MouseButton1Click:Connect(function()
                setOpen(not open)
            end))
            obj:Refresh(options or {})
            obj:Set(default, true)
            return obj
        end

        -- Live status panel. :Set() is safe from any thread; the window's
        -- Heartbeat applies the text.
        function tab:Status(titleText)
            local r = row(58)
            r.AutomaticSize = Enum.AutomaticSize.Y
            local t = label(titleText, 12, Theme.SubText, Theme.FontBold)
            t.Position = UDim2.fromOffset(12, 8)
            t.Size = UDim2.new(1, -24, 0, 16)
            t.Parent = r
            local body = label("…", 13, Theme.Text)
            body.TextWrapped = true
            body.TextYAlignment = Enum.TextYAlignment.Top
            body.AutomaticSize = Enum.AutomaticSize.Y
            body.Position = UDim2.fromOffset(12, 28)
            body.Size = UDim2.new(1, -24, 0, 18)
            body.Parent = r
            new("UIPadding", { PaddingBottom = UDim.new(0, 10), Parent = r })
            local dot = new("Frame", {
                AnchorPoint = Vector2.new(1, 0),
                Position = UDim2.new(1, -12, 0, 12),
                Size = UDim2.fromOffset(8, 8),
                BackgroundColor3 = Theme.SubText,
                Parent = r,
            }, { corner(9999) })

            local s = { body = body, text = "…", color = Theme.Text, dirty = false }
            table.insert(statuses, s)
            local obj = {}
            function obj:Set(text, kind)
                s.text = tostring(text)
                s.color = kind and Theme[kind] or Theme.Text
                s.dirty = true
            end
            -- Pulse the dot while work is running: obj:SetActive(true/false)
            local pulse
            function obj:SetActive(on)
                if pulse then
                    pulse:Cancel()
                    pulse = nil
                end
                dot.BackgroundTransparency = 0
                dot.BackgroundColor3 = on and Theme.Good or Theme.SubText
                if on then
                    pulse = tween(dot, TweenInfo.new(0.8, Enum.EasingStyle.Sine,
                        Enum.EasingDirection.InOut, -1, true), { BackgroundTransparency = 0.7 })
                end
            end
            return obj
        end

        if #win.Tabs == 1 then
            task.defer(function()
                selectTab(tab)
            end)
        end
        return tab
    end

    task.defer(function()
        win:Show()
    end)
    return win
end

return UIFX

end)()

local UI = { win = nil, farm = nil, progress = nil, tower = nil, chain = nil, logs = nil }
do
    UI.win = UIFX.Window({
        Title = "Anime Dice · Chain",
        Size = UDim2.fromOffset(540, 400),
        ToggleKey = Enum.KeyCode.RightControl,
        OnClose = function()
            -- a newer run replacing this window must keep running: only clear our own token
            if LP:GetAttribute("AnimeDiceRun") == TOKEN then
                LP:SetAttribute("AnimeDiceRun", nil)
                log("stopped (window closed)")
            end
        end,
    })
    local main = UI.win:Tab("Status")
    UI.farm = main:Status("FARM")
    UI.progress = main:Status("PROGRESS")
    UI.tower = main:Status("TOWER")
    UI.chain = main:Status("CHAIN")
    UI.logs = main:Status("LOG")

    local ctl = UI.win:Tab("Controls")
    ctl:Section("Toggles")
    ctl:Toggle("Farm (roll · sell · buy · rebirth)", S.farm, function(on)
        S.farm = on
    end)
    ctl:Toggle("Towers", S.towerOn, function(on)
        S.towerOn = on
    end)
    ctl:Toggle("Chain build", S.chainOn, function(on)
        S.chainOn = on
    end)
    ctl:Section("Actions")
    ctl:Button("Sell overflow now", function()
        SYS.sell(true)
        UI.win:Notify(S.lastSell, "Good", 3)
    end)
    ctl:Button("Re-redeem codes", function()
        S.codesDone = false
        SYS.rewards()
    end)
    ctl:Button("Write chain file now", function()
        CH.write()
        UI.win:Notify("wrote " .. chainFile(LP.Name), "Good", 3)
    end)
end

function UI.refresh()
    local count, cap = H.storage()
    UI.farm:Set(string.format("%s · %d rolls/min · units %d/%d\n$%s (+%s/s) · %s\n%s",
        S.farm and (S.pauseRoll and "paused for trade" or "running") or "off",
        SYS.rollsPerMin(), count, cap,
        H.fmt(D.Money()), H.fmt(H.incomePerSec()), S.lastSell ~= "" and S.lastSell or "no sale yet",
        S.lastSpend ~= "" and ("last buy: " .. S.lastSpend) or ""), S.farm and "Text" or "Warn")
    UI.farm:SetActive(S.farm and not S.pauseRoll)

    local mx = SYS.maxed()
    UI.progress:Set(string.format("Rebirth %d/%d · Dice %s (top %s)\nUpgrades %d/%d · tickets %d\n%s",
        D.Rebirth(), S.rebirthTarget, tostring(D.Dice()), tostring(S.topDice),
        H.upgradesOwned(), S.upgradeTotal, H.tickets(),
        mx.ok and "MAXED (" .. table.concat(CFG.Chain.MaxedWhen, "+") .. ")" or ("need: " .. mx.text)),
        mx.ok and "Good" or "Text")

    local tw = S.tower
    UI.tower:Set(string.format("%s · %s floor %d (sim %d) · runs %d",
        S.towerOn and "on" or "off", tw.name, tw.floor, tw.predicted, tw.runs) .. "\n" .. tostring(tw.msg))
    UI.tower:SetActive(S.towerOn and tw.msg == "running")

    local ch = S.chain
    UI.chain:Set((S.chainOn and (ch.role .. " · " .. ch.phase) or "off") .. "\n" .. tostring(ch.msg)
        .. "\nAFK guard: " .. S.afk .. " · rejoin: " .. S.rejoin, ch.done and "Good" or (ch.phase == "send" or ch.phase == "host") and "Accent" or "Text")
    UI.chain:SetActive(S.chainOn and (ch.phase == "send" or ch.phase == "host"))

    local lines = {}
    for _, l in ipairs(S.logLines) do
        table.insert(lines, l.text)
    end
    UI.logs:Set(#lines > 0 and table.concat(lines, "\n") or "-")
end

function UI.manager()
    if S.chain.done then
        return
    end
    local phase = S.chainOn and S.chain.phase or "farm"
    local desc = string.format("R%d/%d %s Upg %d/%d $%s %s",
        D.Rebirth(), S.rebirthTarget, tostring(D.Dice()), H.upgradesOwned(), S.upgradeTotal,
        H.fmt(D.Money()), phase)
    MGR.status(desc, {
        __order = { "Rebirth", "Dice", "Upgrades", "Money", "Phase" },
        Rebirth = D.Rebirth() .. "/" .. S.rebirthTarget,
        Dice = tostring(D.Dice()),
        Upgrades = H.upgradesOwned() .. "/" .. S.upgradeTotal,
        Money = H.fmt(D.Money()),
        Phase = phase,
    })
end

-- ════════════════════════════════════════════════════════════
-- START
-- ════════════════════════════════════════════════════════════
log(string.format("loaded · %s · rebirth %d/%d · top dice %s · %d upgrades · PlaceId %d",
    LP.Name, D.Rebirth(), S.rebirthTarget, tostring(S.topDice), S.upgradeTotal, game.PlaceId))
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
task.spawn(function()
    local n = 0
    while alive() do
        n = n + 1
        local ok, err = pcall(UI.refresh)
        if not ok and n % 10 == 1 then
            log("ui error: " .. tostring(err), "Bad")
        end
        if n % 10 == 0 then
            pcall(UI.manager)
        end
        task.wait(1)
    end
    pcall(function()
        UI.win:Destroy()
    end)
end)
UI.win:Notify("Anime Dice loaded · RightCtrl hides", "Good", 4)
