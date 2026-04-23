-- HSZombieMod v25
-- NotifyOnNewObject queues new Willie_BP_C spawns; zombify key drains the queue first.
-- Edit Scripts/config.lua to change keybindings.

local UEHelpers = require("UEHelpers")

-- ============================================================
--  CONFIG
-- ============================================================

local cfg = { zombify_key = "1", spawn_key = "h", spawn_naked_key = "k", spawn_count = 1 }
pcall(function()
    local loaded = require("config")
    if type(loaded) == "table" then
        for x, v in pairs(loaded) do cfg[x] = v end
    end
end)

local ZOMBIFY_KEY     = Key[cfg.zombify_key]     or Key.g
local SPAWN_KEY       = Key[cfg.spawn_key]       or Key.h
local SPAWN_NAKED_KEY = Key[cfg.spawn_naked_key] or Key.k

-- ============================================================
--  HELPERS
-- ============================================================

local function IsPlayer(pawn)
    local ok, val = pcall(function() return pawn["Player"] end)
    return ok and val == true
end

local function IsHumanEnemy(pawn)
    if not pawn or not pawn:IsValid() then return false end
    if IsPlayer(pawn) then return false end
    local ok, name = pcall(function()
        return pawn:GetClass():GetFName():ToString()
    end)
    return ok and name == "Willie_BP_C"
end

-- ============================================================
--  ZOMBIE CLASS LOADER
-- ============================================================

local cachedZombieClass = nil

local function GetZombieClass()
    if cachedZombieClass and cachedZombieClass:IsValid() then
        return cachedZombieClass
    end
    local cls = StaticFindObject("/Game/Character/Blueprints/Willie_BP_Zombie.Willie_BP_Zombie_C")
    if cls and cls:IsValid() then cachedZombieClass = cls; return cls end

    local ok, cls2 = pcall(function()
        local arh = StaticFindObject("/Script/AssetRegistry.Default__AssetRegistryHelpers")
        if not arh or not arh:IsValid() then return nil end
        local loaded = arh:GetAsset({
            ["PackageName"] = UEHelpers.FindOrAddFName("/Game/Character/Blueprints/Willie_BP_Zombie"),
            ["AssetName"]   = UEHelpers.FindOrAddFName("Willie_BP_Zombie_C"),
        })
        return (loaded and loaded:IsValid()) and loaded or nil
    end)
    if ok and cls2 then cachedZombieClass = cls2; return cls2 end

    local ex = FindFirstOf("Willie_BP_Zombie_C")
    if ex and ex:IsValid() then
        cachedZombieClass = ex:GetClass(); return cachedZombieClass
    end
    return nil
end

-- ============================================================
--  DONOR ZOMBIE — kept alive so its mesh asset + MIDs stay valid
-- ============================================================

local donorZombie        = nil
local cachedRevenantMesh = nil
local cachedZombieMaterials = nil

local function GetDonorData(world, zombieClass)
    if donorZombie and donorZombie:IsValid()
            and cachedRevenantMesh and cachedZombieMaterials then
        return cachedRevenantMesh, cachedZombieMaterials
    end

    local donor = nil
    pcall(function()
        donor = world:SpawnActor(zombieClass,
            {X = 0.0, Y = 0.0, Z = -100000.0},
            {Pitch = 0.0, Yaw = 0.0, Roll = 0.0})
    end)

    if not donor or not donor:IsValid() then
        print("[HSZ] Donor zombie spawn failed")
        return nil, nil
    end

    pcall(function() donor["Team Int"] = 99 end)

    local meshComp = nil
    pcall(function()
        local mc = donor["Mesh"]
        if mc and mc:IsValid() then meshComp = mc end
    end)

    if not meshComp then
        print("[HSZ] Donor mesh component not found")
        pcall(function() donor:K2_DestroyActor() end)
        return nil, nil
    end

    local revenantMesh = nil
    pcall(function()
        local sm = meshComp:GetSkeletalMeshAsset()
        if sm and sm:IsValid() then revenantMesh = sm end
    end)

    local mats = {}
    pcall(function()
        for i = 0, 15 do
            local ok, mat = pcall(function() return meshComp:GetMaterial(i) end)
            if ok and mat and mat:IsValid() then
                mats[i] = mat
            else
                break
            end
        end
    end)

    if not revenantMesh and next(mats) == nil then
        print("[HSZ] Donor yielded no mesh or materials — destroying")
        pcall(function() donor:K2_DestroyActor() end)
        return nil, nil
    end

    donorZombie           = donor
    cachedRevenantMesh    = revenantMesh
    cachedZombieMaterials = (next(mats) ~= nil) and mats or nil

    local meshName = revenantMesh and revenantMesh:GetFName():ToString() or "(none)"
    local matCount = 0
    if cachedZombieMaterials then
        for _ in pairs(cachedZombieMaterials) do matCount = matCount + 1 end
    end
    print(string.format("[HSZ] Donor ready — mesh=%s  materials=%d", meshName, matCount))

    return cachedRevenantMesh, cachedZombieMaterials
end

-- ============================================================
--  CORE: ZOMBIFY IN PLACE
-- ============================================================

local function ZombifyOne(enemy, revenantMesh, zombieMaterials)
    if not IsHumanEnemy(enemy) then return false end
    pcall(function()
        local meshComp = enemy["Mesh"]
        if not meshComp or not meshComp:IsValid() then return end

        -- 1. Swap base skeletal mesh to SK_Revenant_A_001
        if revenantMesh then
            pcall(function() meshComp:SetSkeletalMeshAsset(revenantMesh) end)
        end

        -- 2. Apply revenant materials to base mesh
        if zombieMaterials then
            for i, mat in pairs(zombieMaterials) do
                pcall(function() meshComp:SetMaterial(i, mat) end)
            end
        end

        -- 3. Per-component fixes
        pcall(function()
            local smcCls = StaticFindObject("/Script/Engine.SkeletalMeshComponent")
            if not smcCls or not smcCls:IsValid() then return end
            local comps = enemy:K2_GetComponentsByClass(smcCls)
            if not comps then return end
            for _, rawComp in ipairs(comps) do
                local comp = nil
                pcall(function() comp = rawComp:get() end)
                if not comp then pcall(function() comp = rawComp end) end
                pcall(function()
                    local cname = comp:GetFName():ToString()

                    if cname == "CharacterMesh_Head" then
                        -- Human face + hair covers the revenant skull — hide it
                        comp:SetVisibility(false, false)

                    elseif cname == "SK_Skeleton" then
                        -- Copy slot[2] skeleton mat to slots [0] (flesh) and [1] (organs)
                        -- so dismembered gibs look skeletal instead of fleshy
                        local ok, skelMat = pcall(function() return comp:GetMaterial(2) end)
                        if ok and skelMat and skelMat:IsValid() then
                            pcall(function() comp:SetMaterial(0, skelMat) end)
                            pcall(function() comp:SetMaterial(1, skelMat) end)
                        end
                    end
                end)
            end
        end)

        -- 4. Zombie behavior flags
        pcall(function() enemy["Is Zombie?"] = true end)
        pcall(function() enemy["Team Int"]   = 2    end)

        -- 5. Anim instance flag
        pcall(function()
            local anim = meshComp:GetAnimInstance()
            if anim and anim:IsValid() then
                anim["Is Zombie?"] = true
            end
        end)
    end)
    return true
end

local function SetAllAIAbyss()
    local ais = FindAllOf("AI_BP_C")
    if not ais then return end
    for _, ai in ipairs(ais) do
        pcall(function()
            if ai and ai:IsValid() then
                ai["Team Int"]   = 2
                ai["Abyss"]      = true
                ai["Is Zombie?"] = true
            end
        end)
    end
end

-- ============================================================
--  QUEUE — catches enemies spawned between F7 presses
-- ============================================================

local pendingPawns = {}

pcall(function()
    NotifyOnNewObject(
        "/Game/Character/Blueprints/Willie_BP.Willie_BP_C",
        function(newPawn)
            if newPawn and newPawn:IsValid() and not IsPlayer(newPawn) then
                table.insert(pendingPawns, newPawn)
            end
        end
    )
end)

-- ============================================================
--  SPAWN EXTRA ZOMBIES around the player
-- ============================================================

local EXTRA_ZOMBIE_COUNT = cfg.spawn_count
local SPAWN_OFFSETS = {
    {X =  350, Y =    0},
    {X = -350, Y =    0},
    {X =    0, Y =  350},
    {X =    0, Y = -350},
}

local function TriggerEnemySpawners(count)
    local spawners = FindAllOf("BP_SpawnerPoint_Willies_C")
    if not spawners or #spawners == 0 then
        print("[HSZ] No spawner actors found")
        return 0
    end

    local triggered = 0
    for _, sp in ipairs(spawners) do
        if triggered >= count then break end
        if sp and sp:IsValid() then
            -- Skip player spawn points
            local isPlayerSpawner = false
            pcall(function() isPlayerSpawner = sp["Spawn Player"] == true end)
            if not isPlayerSpawner then
                pcall(function()
                    sp["Spawned Amount"] = 0  -- reset so it's willing to re-spawn
                    local fn = sp["Spawn Willies"]
                    if fn then fn(1) end      -- NPC Amount = 1
                end)
                triggered = triggered + 1
            end
        end
    end
    print("[HSZ] Triggered " .. triggered .. " enemy spawners")
    return triggered
end

-- ============================================================
--  F7: ZOMBIFY ALL
-- ============================================================

RegisterKeyBind(ZOMBIFY_KEY, {}, function()
    ExecuteInGameThread(function()
        local world = UEHelpers.GetWorld()
        if not world or not world:IsValid() then return end
        local zombieClass = GetZombieClass()
        if not zombieClass then print("[HSZ] Class unavailable"); return end

        local revenantMesh, zombieMats = GetDonorData(world, zombieClass)
        if not revenantMesh and not zombieMats then
            print("[HSZ] No donor data — aborting")
            return
        end

        -- Drain queued spawns first, then sweep all current Willies
        local toProcess = pendingPawns
        pendingPawns = {}

        local willies = FindAllOf("Willie_BP_C")
        if willies then
            for _, w in ipairs(willies) do
                toProcess[#toProcess + 1] = w
            end
        end

        local n = 0
        local seen = {}
        for _, pawn in ipairs(toProcess) do
            local addr = tostring(pawn:GetAddress())
            if not seen[addr] then
                seen[addr] = true
                if ZombifyOne(pawn, revenantMesh, zombieMats) then n = n + 1 end
            end
        end

        if n > 0 then SetAllAIAbyss(); print("[HSZ] Zombified " .. n) end
    end)
end)

-- ============================================================
--  O: SPAWN EXTRA ENEMIES (arm them, then press P to zombify)
-- ============================================================

RegisterKeyBind(SPAWN_KEY, {}, function()
    ExecuteInGameThread(function()
        TriggerEnemySpawners(EXTRA_ZOMBIE_COUNT)
    end)
end)

-- ============================================================
--  I: SPAWN NAKED ZOMBIE directly near the player
-- ============================================================

local function SpawnNakedZombie()
    local world = UEHelpers.GetWorld()
    if not world or not world:IsValid() then return end

    local zombieClass = GetZombieClass()
    if not zombieClass then print("[HSZ] Zombie class unavailable"); return end

    -- Find player pawn for spawn location
    local player = nil
    pcall(function()
        local controller = UEHelpers.GetPlayerController()
        if controller and controller:IsValid() then
            player = controller:K2_GetPawn()
        end
    end)

    local spawnLoc = {X = 0.0, Y = 0.0, Z = 0.0}
    if player and player:IsValid() then
        pcall(function()
            local loc = player:K2_GetActorLocation()
            -- Spawn 300 units in front of the player
            local rot = player:K2_GetActorRotation()
            local yawRad = math.rad(rot.Yaw)
            spawnLoc = {
                X = loc.X + math.cos(yawRad) * 300,
                Y = loc.Y + math.sin(yawRad) * 300,
                Z = loc.Z,
            }
        end)
    end

    local zombie = nil
    pcall(function()
        zombie = world:SpawnActor(zombieClass,
            spawnLoc,
            {Pitch = 0.0, Yaw = 0.0, Roll = 0.0})
    end)

    if not zombie or not zombie:IsValid() then
        print("[HSZ] Naked zombie spawn failed")
        return
    end

    pcall(function() zombie["Team Int"]   = 2    end)
    pcall(function() zombie["Is Zombie?"] = true end)
    pcall(function()
        local anim = zombie["Mesh"] and zombie["Mesh"]:IsValid()
            and zombie["Mesh"]:GetAnimInstance()
        if anim and anim:IsValid() then anim["Is Zombie?"] = true end
    end)

    -- Set AI abyss so it attacks the player
    pcall(function()
        local ais = FindAllOf("AI_BP_C")
        if not ais then return end
        for _, ai in ipairs(ais) do
            pcall(function()
                if ai and ai:IsValid() then
                    local pawn = ai["Pawn"]
                    if pawn and pawn:GetAddress() == zombie:GetAddress() then
                        ai["Team Int"]   = 2
                        ai["Abyss"]      = true
                        ai["Is Zombie?"] = true
                    end
                end
            end)
        end
    end)

    print("[HSZ] Naked zombie spawned")
end

RegisterKeyBind(SPAWN_NAKED_KEY, {k}, function()
    ExecuteInGameThread(SpawnNakedZombie)
end)

print(string.format("[HSZombieMod] v25 — %s: zombify all | %s: spawn %d armed | %s: spawn naked zombie",
    cfg.zombify_key, cfg.spawn_key, EXTRA_ZOMBIE_COUNT, cfg.spawn_naked_key))
