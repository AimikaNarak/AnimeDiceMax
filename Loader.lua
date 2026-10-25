-- ╔══════════════════════════════════════════════════════════╗
--   Anime Dice · Chain Builder — แก้แค่ค่าในตารางนี้พอ
--   ทุกจอใช้ไฟล์นี้ไฟล์เดียวกันได้ (สคริปต์รู้เองว่าจอไหนเป็นใครจากชื่อไอดี)
--   ซ่อน/โชว์หน้าต่าง = ปุ่ม RightCtrl
-- ╚══════════════════════════════════════════════════════════╝
repeat task.wait() until game:IsLoaded()
repeat task.wait() until game.Players.LocalPlayer

getgenv().AnimeDice = {

    -- ▸ ฟาร์มพื้นฐาน (ทอย · เก็บเงิน · วางตัวดีสุด · ซื้ออัพ/เต๋า · rebirth · เควส · โค้ด)
    Farm = {
        Start      = true,   -- เริ่มทันทีตอนโหลด (false = รอกดเปิดในหน้า Controls)
        Graphics   = 1,      -- 0 = ภาพปกติ · 1 = ภาพต่ำ ปิดเอฟเฟกต์ · 2 = แบบ 1 + ปิดภาพ 3D และล็อก 20 FPS (เปิดหลายจอ)
        LevelUnits = true,   -- อัพเลเวลตัวที่วางบ้าน เฉพาะครั้งที่เงินคืนทุนใน 10 นาที
        AutoItems  = true,   -- กินยาทุกขวด ทุกขั้น ทุกสาย (Income/Luck/Damage · Slayer · Shadow ฯลฯ) + ใช้ Lucky Spin (ไม่แตะ Jackpot Spin)
    },

    -- ▸ ขายตัวล้นกระเป๋า (ตัวที่วางบ้าน · ตัวในทีม tower · ตัวที่ล็อก · ตัวใน Chain.Units ไม่โดนขาย)
    Sell = {
        FreeSlots       = 10, -- ช่องว่างเหลือน้อยกว่านี้ → ขาย
        KeepIncomeAbove = 0,      -- 0 = ขายทุกตัวที่ไม่ได้วาง · เก็บตัวที่ทำเงิน/วิ ≥ ค่านี้ · ใส่ได้ทั้ง 1e16 หรือ "10qd" "5t" "895t" (ตัวย่อแบบในเกม)
    },

    -- ▸ Rebirth
    Rebirth = {
        Stats  = { "Money" }, -- ลงแต้มอะไร วนตามลำดับ · {} = ไม่ลง
                              -- ชื่อที่มี: "Luck" "Money" "Damage" "Health" "Trait Luck" "Grade Luck"
        StopAt = 0,           -- 0 = rebirth จนตันเกม (ตอนนี้ 18) · ใส่เลข = หยุดแค่นั้น
    },

    -- ▸ Tower (เล่นไปพร้อมกับทอยได้ ไม่ทำให้ทอยช้าลง)
    Tower = {
        Enabled  = true,
        Pick     = "best",   -- "best" = จำลองการสู้แล้วเลือกเอง: ดันสูงสุดที่ผ่านครบ → Infinity (ถ้าถึงชั้น 25) → ดันที่ไปได้ไกลสุด
                             -- "list" = วนดันตามลำดับใน Only
        Only     = {},       -- {} = ทุกดัน (ไม่รวมดันอีเวนต์ฮาโลวีน) · { "Shadow Tower" } = ดันเดียว
        Infinity = true,     -- นับ "Infinity Tower" เป็นตัวเลือกด้วยไหม
    },

    -- ▸ แลกตั๋วเควส · {} = ไม่แลก · ใส่ชื่อตามลำดับความสำคัญ เช่น { "Luck", "More Cash", "Lucky Spin" }
    --   ชื่อที่มี: "Trait Reroll" "Gems" "Reset Token" "Luck" "Ultra Luck" "More Cash" "Roll Speed"
    --             "More Grades" "More Traits" "Lucky Spin"   (เกมพาสที่มีแล้วจะข้ามเอง)
    TicketShop = {},

    -- ══════ ★ Chain: ปั้นไอดีทีละตัวจนตัน → ส่งตัวละคร(+เกียร์)ต่อให้ไอดีถัดไป ══════
    Chain = {
        Enabled = true,

        -- ลำดับปั้น = ชื่อไอดีจริง (ไม่ใช่ display name) · ตัวแรก = ตัวที่ถือของตั้งต้น
        -- ทุกไอดีต้อง roll ≥ 1000 และอายุ ≥ 14 วัน (กฎเทรดของเกม) · ทุกจอต้องรันบนเครื่องเดียวกัน
        Order = { "ไอดีที่1", "ไอดีที่2", "ไอดีที่3" },

        -- ตัวละครที่ส่งต่อ (ชื่อต้องตรงเป๊ะ รวม Huge / Titanic) · ส่งทุกตัวที่ชื่อตรง และล็อกกันขายให้เอง
        -- {} = ส่งตัวที่ทำเงินสูงสุด TopUnits ตัวแทน
        Units    = { "Huge Princess Serenity", "Titanic Jojo Kudo" },
        TopUnits = 2,
        SendGear = true,      -- ส่งเกียร์ที่ใส่อยู่ไปด้วย (ตัวรับใส่ให้เอง)

        -- "ตัน" = ครบทุกข้อในนี้ · {} = ครบทั้ง 3
        --   "Rebirth"  = rebirth ถึง Rebirth.StopAt (หรือสูงสุดของเกม)
        --   "Dice"     = มีเต๋าแพงสุดของเกม (ตอนนี้ Skeleton)
        --   "Upgrades" = อัพเกรดครบทุกสาย (ตอนนี้ 176)
        MaxedWhen = { "Rebirth", "Dice", "Upgrades" },
        UpgradeGiveUpMin = 0, -- 0 = รออัพให้ครบจริง · เลข = ไม่ได้ซื้ออัพเพิ่มกี่นาที + ที่เหลือแพงกว่าเงินที่มี → นับว่าตัน

        LeaveWhenDone = true, -- ใช้เฉพาะตอน Manager = "None": ส่งของเสร็จแล้วออกเกมเอง · ถ้ามี Masterp/Horst จะแจ้ง Done ให้โปรแกรมปิดเกมแทน
    },

    -- ▸ การย้ายเซิร์ฟเพื่อเทรด (ตัวที่ถือ Unit อยู่กับที่ · ตัวรับวาร์ปมาหา)
    Trade = {
        HostHop       = true, -- ตัวที่ถือ Unit ย้ายเซิร์ฟเฉพาะตอนเซิร์ฟเต็ม/เป็นเซิร์ฟส่วนตัว (ตัวรับเข้าไม่ได้) · false = ไม่ย้ายเลย
        FreeSlots     = 1,    -- ตัวที่ถือ Unit ถือว่าเซิร์ฟเต็มเมื่อที่ว่าง < FreeSlots + 1
        WaitAfterJoin = 180,  -- อยู่เซิร์ฟเดียวกันแล้วรอกี่วิก่อนเทรด (กันเกมเด้ง "Your trade needs recovery")
    },

    -- ▸ โปรแกรมจัดการไอดี (ส่งสถานะ + แจ้ง DONE)
    --   "Auto"    = เจอ Horst หรือ Masterp ตัวไหนก็ใช้ตัวนั้นเอง
    --   "Horst" · "Masterp" · "Storm" (ต้องเปิด Storm Launcher ไว้) · "None" = ไม่ส่ง
    Manager = "Auto",
}

loadstring(game:HttpGet("https://raw.githubusercontent.com/AimikaNarak/AnimeDiceMax/main/AnimeDiceMax.lua"))()
