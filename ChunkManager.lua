
--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MountainUtil = require(ReplicatedStorage.Modules.MountainUtil)
local MountainConfig = MountainUtil.config()
local MountainDebugOverlay = require(ReplicatedStorage.Modules.MountainDebugOverlay)

local ChunkManager = {}
ChunkManager.__index = ChunkManager

export type Settings = {
    VoxelSize: number,
    CellsPerAxis: number,
    YCells: number,
    RenderRadius: number,
    PreloadEdge: number?,
    MaxWorkers: number,
    LODBands: { { maxDist: number, factor: number } }?,
}

local function getManagerActor()
    local plr = Players.LocalPlayer
    if not plr then
        return nil
    end
    local ps = plr:FindFirstChildOfClass("PlayerScripts")
    return ps and ps:FindFirstChild("MesherManagerActor")
end

local function requestUnloadOnManager(key: string)
    local mgrActor = getManagerActor()
    if mgrActor then
        mgrActor:SendMessage("unloadChunk", { Key = key })
    end
end

local function keyFor(cx: number, cy: number, cz: number, tileId: number?): string
    if tileId and tileId ~= 0 then
        return string.format("%d:%d:%d:%d", cx, cy, cz, tileId)
    end
    return string.format("%d:%d:%d", cx, cy, cz)
end

local function ringIter(r: number)
    local function line(ax, az, bx, bz, acc)
        local dx = bx - ax
        local dz = bz - az
        local n = math.max(math.abs(dx), math.abs(dz))
        if n <= 0 then
            return
        end
        for i = 0, n do
            local t = i / n
            acc[#acc + 1] = {
                math.floor(ax + t * dx + 0.5),
                math.floor(az + t * dz + 0.5),
            }
        end
    end
    local acc = {}
    if r == 0 then
        acc[1] = { 0, 0 }
        return acc
    end
    line(-r, -r, r, -r, acc)
    line(r, -r, r, r, acc)
    line(r, r, -r, r, acc)
    line(-r, r, -r, -r, acc)
    return acc
end

local function cloneActor(actorTemplate: Instance)
    local plr = Players.LocalPlayer
    local ps = plr and plr:FindFirstChildOfClass("PlayerScripts")
    local a = actorTemplate:Clone()
    a.Name = "MesherActor_" .. tostring(math.random(1000000, 9999999))
    if ps then
        a.Parent = ps
    else
        a.Parent = actorTemplate.Parent
    end
    return a
end

local function dimsFor(factor: number, baseCells: number, baseY: number): Vector3int16
    return Vector3int16.new(
        math.max(2, math.floor(baseCells / factor + 0.5)),
        math.max(2, math.floor(baseY / factor + 0.5)),
        math.max(2, math.floor(baseCells / factor + 0.5))
    )
end

local function chooseLODFactorSmart(bands, ringDist: number, studsDist: number, settings: Settings): (number, number)
    local useRings = false
    if bands and #bands > 0 then
        local th = bands[1].maxDist
        if type(th) == "number" and th <= (settings.RenderRadius + 0.5) then
            useRings = true
        end
    end
    local metric = useRings and ringDist or studsDist
    for i = 1, #bands do
        if metric <= bands[i].maxDist then
            return bands[i].factor, i - 1
        end
    end
    return bands[#bands].factor, #bands - 1
end

local function estimateGroundCost(dims: Vector3int16): (number, number)
    local tris = dims.X * dims.Y * dims.Z * 2
    local verts = (dims.X + 1) * (dims.Y + 1) * (dims.Z + 1)
    return tris, verts
end

local function ensureFolder(name: string): Folder
    local f = workspace:FindFirstChild(name)
    if not f then
        f = Instance.new("Folder")
        f.Name = name
        f.Parent = workspace
    end
    return f
end

function ChunkManager.new(actorTemplate: Instance, settings: Settings)
    local self = setmetatable({}, ChunkManager)
    self.settings = settings
    self.actorTemplate = actorTemplate

    self.activeChunks = {}
    self.pending = {}
    self.workers = {}
    self.freeWorkers = {}
    self.chunkLOD = {}
    self.pendingLOD = {}
    self.jobQueue = {}
    self.deferredJobs = {}
    self.pendingEstimates = {}
    self.activeStats = {}
    self.lastUpgrade = {}
    self.bandMeta = {}
    self.mountainTagged = {}

    self.chunkFolder = ensureFolder("ClientChunks")
    self.debugOverlay = MountainDebugOverlay.new()

    self.budgetCaps = {
        tris = (MountainConfig.Budget and MountainConfig.Budget.GlobalTriCap) or math.huge,
        verts = (MountainConfig.Budget and MountainConfig.Budget.GlobalVertCap) or math.huge,
    }
    self.budgetThresholds = MountainConfig.Budget and MountainConfig.Budget.PressureThresholds or {}
    self.usageActual = { tris = 0, verts = 0 }
    self.usagePending = { tris = 0, verts = 0 }
    self.pressureStage = 0

    self.cooldownSeconds = MountainConfig.CooldownSeconds or 0
    self.baseYOffset = settings.VoxelSize * 2.0

    for _ = 1, settings.MaxWorkers do
        local a = cloneActor(actorTemplate)
        local rec = { Actor = a, Busy = false }
        table.insert(self.workers, rec)
        table.insert(self.freeWorkers, rec)
    end

    return self
end

function ChunkManager:_reserveCost(key: string, tris: number, verts: number)
    local prev = self.pendingEstimates[key]
    if prev then
        self.usagePending.tris = math.max(0, self.usagePending.tris - prev.tris)
        self.usagePending.verts = math.max(0, self.usagePending.verts - prev.verts)
    end
    self.pendingEstimates[key] = { tris = tris, verts = verts }
    self.usagePending.tris += tris
    self.usagePending.verts += verts
end

function ChunkManager:_releasePending(key: string)
    local prev = self.pendingEstimates[key]
    if prev then
        self.usagePending.tris = math.max(0, self.usagePending.tris - prev.tris)
        self.usagePending.verts = math.max(0, self.usagePending.verts - prev.verts)
        self.pendingEstimates[key] = nil
    end
end

function ChunkManager:_applyStats(key: string, tris: number, verts: number)
    local prev = self.activeStats[key]
    if prev then
        self.usageActual.tris = math.max(0, self.usageActual.tris - prev.tris)
        self.usageActual.verts = math.max(0, self.usageActual.verts - prev.verts)
    end
    self.activeStats[key] = { tris = tris, verts = verts }
    self.usageActual.tris += tris
    self.usageActual.verts += verts
end

function ChunkManager:_removeStats(key: string)
    local prev = self.activeStats[key]
    if prev then
        self.usageActual.tris = math.max(0, self.usageActual.tris - prev.tris)
        self.usageActual.verts = math.max(0, self.usageActual.verts - prev.verts)
        self.activeStats[key] = nil
    end
end

function ChunkManager:_ratioWithAdditional(tris: number, verts: number): number
    local triCap = self.budgetCaps.tris
    local vertCap = self.budgetCaps.verts
    local totalTri = self.usageActual.tris + self.usagePending.tris + tris
    local totalVert = self.usageActual.verts + self.usagePending.verts + verts
    local triRatio = (triCap > 0) and (totalTri / triCap) or 0
    local vertRatio = (vertCap > 0) and (totalVert / vertCap) or 0
    return math.max(triRatio, vertRatio)
end

function ChunkManager:_updatePressure(): (number, number)
    local ratio = self:_ratioWithAdditional(0, 0)
    local thresholds = self.budgetThresholds or {}
    local prevStage = self.pressureStage or 0
    local stage = 0
    if thresholds.Defer and ratio >= thresholds.Defer then
        stage = 3
    elseif thresholds.SkipLowerBands and ratio >= thresholds.SkipLowerBands then
        stage = 2
    elseif thresholds.Simplify and ratio >= thresholds.Simplify then
        stage = 1
    end
    if stage ~= prevStage then
        print(string.format("[ChunkManager][Mountain] pressure stage %d->%d (ratio=%.3f)", prevStage, stage, ratio))
    end
    self.pressureStage = stage
    return stage, ratio
end

function ChunkManager:_ensureMarker(key: string)
    local marker = self.activeChunks[key]
    if marker then
        return marker
    end
    marker = Instance.new("BoolValue")
    marker.Name = key
    marker.Value = false
    marker:SetAttribute("JobNonce", 0)
    marker:SetAttribute("Pending", true)
    marker.Parent = self.chunkFolder
    self.activeChunks[key] = marker
    return marker
end

function ChunkManager:_buildPayload(job)
    local payload = {
        Key = job.key,
        Origin = job.origin,
        VoxelSize = job.voxelSize,
        BaseVoxelSize = self.settings.VoxelSize,
        Dims = job.dims,
        LODLevel = job.lodIdx,
        TileId = job.tileId,
        EstimatedCost = {
            Tris = job.estimatedTris,
            Verts = job.estimatedVerts,
        },
        EdgeLengthTarget = job.edgeLength,
        PressureStage = self.pressureStage,
    }
    if job.mountain then
        payload.Mountain = {
            BandIndex = job.mountain.bandIndex,
            BandName = job.mountain.bandName,
            MaskStrength = job.mountain.maskStrength,
            TopY = job.mountain.topY,
            BottomY = job.mountain.bottomY,
            TileId = job.tileId,
            SegmentIndex = job.mountain.segmentIndex or job.segmentIndex or 0,
            IsMountain = true,
        }
    end
    return payload
end

function ChunkManager:_scheduleJob(job, wanted, now)
    local key = job.key
    local thresholds = self.budgetThresholds or {}
    local projected = self:_ratioWithAdditional(job.estimatedTris, job.estimatedVerts)
    if thresholds.Defer and projected >= thresholds.Defer then
        self.deferredJobs[key] = job
        if self.activeChunks[key] then
            wanted[key] = true
        end
        print(string.format("[ChunkManager][Mountain] defer %s ratio=%.3f stage=%d", key, projected, self.pressureStage))
        return false
    end
    if self.pressureStage >= 2 and job.mountain and job.mountain.bandIndex > 1 then
        if self.activeChunks[key] then
            wanted[key] = true
        end
        print(string.format("[ChunkManager][Mountain] skip lower band %s stage=%d", key, self.pressureStage))
        return false
    end

    self:_reserveCost(key, job.estimatedTris, job.estimatedVerts)
    local marker = self:_ensureMarker(key)
    wanted[key] = true
    self.bandMeta[key] = job
    if marker then
        marker:SetAttribute("BandIndex", job.mountain and job.mountain.bandIndex or 0)
        marker:SetAttribute("TileId", job.tileId or 0)
        marker:SetAttribute("IsMountain", job.mountain ~= nil)
        marker:SetAttribute("TopY", job.mountain and job.mountain.topY or 0)
        marker:SetAttribute("BottomY", job.mountain and job.mountain.bottomY or 0)
        marker:SetAttribute("SegmentIndex", job.mountain and job.mountain.segmentIndex or job.segmentIndex or 0)
    end

    local currentLOD = self.chunkLOD[key]
    if currentLOD ~= nil and job.lodIdx > currentLOD then
        local lastUp = self.lastUpgrade[key] or 0
        if now - lastUp < self.cooldownSeconds then
            self:_releasePending(key)
            return true
        end
    end

    job.edgeLength = (MountainConfig.Simplification and MountainConfig.Simplification.BaseEdgeLength and MountainConfig.Simplification.BaseEdgeLength[job.lodIdx]) or 10.0
    if self.pressureStage >= 1 then
        local factor = MountainConfig.Simplification and MountainConfig.Simplification.PressureFactor or 1.0
        job.edgeLength *= factor
    end
    job.voxelSize = self.settings.VoxelSize * job.factor
    job.payload = self:_buildPayload(job)
    self.pendingLOD[key] = job.lodIdx

    if self.debugOverlay then
        local size = Vector3.new(job.dims.X * job.voxelSize, job.dims.Y * job.voxelSize, job.dims.Z * job.voxelSize)
        local center = job.origin + size * 0.5
        self.debugOverlay:update({
            key = key,
            center = center,
            size = size,
            bandIndex = job.mountain and job.mountain.bandIndex or 0,
        })
    end

    if #self.freeWorkers <= 0 then
        self.jobQueue[key] = job
        return true
    end

    local worker = table.remove(self.freeWorkers, #self.freeWorkers)
    worker.Busy = true
    worker.Actor:SendMessage("generateMesh", job.payload)
    self.pending[key] = worker
    if job.mountain then
        local segIndex = job.mountain and job.mountain.segmentIndex or job.segmentIndex or 0
        print(string.format("[ChunkManager][Mountain] dispatch %s LOD=%d seg=%d stage=%d", key, job.lodIdx, segIndex, self.pressureStage))
    end
    return true
end

function ChunkManager:_planGroundJob(cx: number, cz: number, lodIdx: number, factor: number, chunkSize: number, baseCells: number, now: number, wanted)
    local key = keyFor(cx, 0, cz)
    local dims = dimsFor(factor, baseCells, self.settings.YCells)
    local origin = Vector3.new(cx * chunkSize, 0, cz * chunkSize)
    local tris, verts = estimateGroundCost(dims)
    local job = {
        key = key,
        cx = cx,
        cy = 0,
        cz = cz,
        tileId = 0,
        lodIdx = lodIdx,
        factor = factor,
        origin = origin,
        dims = dims,
        estimatedTris = tris,
        estimatedVerts = verts,
    }
    self:_scheduleJob(job, wanted, now)
end

function ChunkManager:_planMountainJobs(cx: number, cz: number, lodIdx: number, factor: number, chunkSize: number, baseCells: number, baseVoxel: number, now: number, wanted)
    local overlapCells = MountainConfig.BandOverlapCells or 0
    local mountainFactor = (MountainConfig.MountainLodFactor and MountainConfig.MountainLodFactor[lodIdx]) or 1.0
    if self.pressureStage >= 1 then
        local factorMult = MountainConfig.Simplification and MountainConfig.Simplification.PressureFactor or 1.0
        mountainFactor *= factorMult
    end
    local bands, maskStrength = MountainUtil.planBands(cx, cz, chunkSize, baseVoxel, baseCells, self.baseYOffset, lodIdx, factor, mountainFactor, overlapCells, self.cooldownSeconds)
    if maskStrength <= 0.01 then
        return false, false
    end
    local tagKey = string.format("%d:%d", cx, cz)
    if not self.mountainTagged[tagKey] then
        self.mountainTagged[tagKey] = true
        print(string.format("[ChunkManager][Mountain] tag chunk %d,%d mask=%.2f lod=%d stage=%d", cx, cz, maskStrength, lodIdx, self.pressureStage))
    end
    local any = false
    for _, job in ipairs(bands) do
        if job.mountain then
            job.mountain.maskStrength = maskStrength
        end
        local keep = self:_scheduleJob(job, wanted, now)
        any = keep or any
    end
    if not any then
        print(string.format("[ChunkManager][Mountain] budget blocked chunk %d,%d LOD=%d", cx, cz, lodIdx))
    end
    return true, any
end

function ChunkManager:_planChunk(cx: number, cz: number, lodIdx: number, factor: number, chunkSize: number, baseCells: number, baseVoxel: number, now: number, wanted)
    if MountainConfig.Enabled ~= false then
        local hasMountain, scheduled = self:_planMountainJobs(cx, cz, lodIdx, factor, chunkSize, baseCells, baseVoxel, now, wanted)
        if hasMountain then
            return scheduled
        end
    end
    self:_planGroundJob(cx, cz, lodIdx, factor, chunkSize, baseCells, now, wanted)
    return true
end

function ChunkManager:_dispatchQueuedJobs()
    if #self.freeWorkers <= 0 then
        return
    end
    for key, job in pairs(self.jobQueue) do
        if #self.freeWorkers <= 0 then
            break
        end
        self.jobQueue[key] = nil
        local worker = table.remove(self.freeWorkers, #self.freeWorkers)
        worker.Busy = true
        worker.Actor:SendMessage("generateMesh", job.payload)
        self.pending[key] = worker
        if job.mountain then
            local segIndex = job.mountain and job.mountain.segmentIndex or job.segmentIndex or 0
            print(string.format("[ChunkManager][Mountain] queued dispatch %s seg=%d", key, segIndex))
        end
    end
end

function ChunkManager:_processDeferredJobs(now: number, wanted)
    if self.pressureStage >= 3 then
        return
    end
    local threshold = (self.budgetThresholds and self.budgetThresholds.Defer) or 1.0
    for key, job in pairs(self.deferredJobs) do
        local ratio = self:_ratioWithAdditional(job.estimatedTris, job.estimatedVerts)
        if ratio < threshold * 0.9 then
            self.deferredJobs[key] = nil
            self:_scheduleJob(job, wanted, now)
        end
    end
end

function ChunkManager:step(centerXZ: Vector2)
    local s = self.settings
    local baseVox = s.VoxelSize
    local baseCells = s.CellsPerAxis
    local radius = s.RenderRadius
    local preload = s.PreloadEdge or 0
    local bands = s.LODBands or {
        { maxDist = radius * baseCells * baseVox * 0.45, factor = 2 },
        { maxDist = radius * baseCells * baseVox * 0.85, factor = 4 },
        { maxDist = math.huge, factor = 8 },
    }

    local chunkSize = baseVox * baseCells
    local wx = math.floor(centerXZ.X / chunkSize)
    local wz = math.floor(centerXZ.Y / chunkSize)
    local lx = centerXZ.X - wx * chunkSize
    local lz = centerXZ.Y - wz * chunkSize
    local now = os.clock()
    local wanted = {}

    self:_updatePressure()

    for r = 0, radius do
        local coords = ringIter(r)
        for _, coord in ipairs(coords) do
            local dx = coord[1]
            local dz = coord[2]
            local cx = wx + dx
            local cz = wz + dz
            local ringDist = math.max(math.abs(dx), math.abs(dz))
            local chunkCenter = Vector3.new((wx + dx) * chunkSize + chunkSize * 0.5, 0, (wz + dz) * chunkSize + chunkSize * 0.5)
            local studsDist = (chunkCenter - Vector3.new(centerXZ.X, 0, centerXZ.Y)).Magnitude
            local factor, lodIdx = chooseLODFactorSmart(bands, ringDist, studsDist, s)
            self:_planChunk(cx, cz, lodIdx, factor, chunkSize, baseCells, baseVox, now, wanted)
        end
    end

    if preload > 0 then
        local factor = bands[1] and bands[1].factor or 1
        local function preloadAt(dx: number, dz: number)
            local cx = wx + dx
            local cz = wz + dz
            self:_planChunk(cx, cz, 0, factor, chunkSize, baseCells, baseVox, now, wanted)
        end
        local nearLeft = (lx <= preload)
        local nearRight = (chunkSize - lx <= preload)
        local nearFront = (lz <= preload)
        local nearBack = (chunkSize - lz <= preload)
        if nearLeft then preloadAt(-1, 0) end
        if nearRight then preloadAt(1, 0) end
        if nearFront then preloadAt(0, -1) end
        if nearBack then preloadAt(0, 1) end
        if nearLeft and nearFront then preloadAt(-1, -1) end
        if nearLeft and nearBack then preloadAt(-1, 1) end
        if nearRight and nearFront then preloadAt(1, -1) end
        if nearRight and nearBack then preloadAt(1, 1) end
    end

    for key, worker in pairs(self.pending) do
        local marker = self.activeChunks[key]
        if marker and marker.Value == true then
            self.pending[key] = nil
            worker.Busy = false
            table.insert(self.freeWorkers, worker)
            local prevLOD = self.chunkLOD[key]
            local newLOD = self.pendingLOD[key] or 0
            self.chunkLOD[key] = newLOD
            self.pendingLOD[key] = nil
            self:_releasePending(key)
            local triAttr = marker:GetAttribute("TriCount")
            local vertAttr = marker:GetAttribute("VertCount")
            if typeof(triAttr) == "number" and typeof(vertAttr) == "number" then
                self:_applyStats(key, triAttr, vertAttr)
            end
            if prevLOD == nil or newLOD < prevLOD then
                self.lastUpgrade[key] = os.clock()
            end
        end
    end

    for key, job in pairs(self.jobQueue) do
        if not wanted[key] then
            self:_releasePending(key)
            self.jobQueue[key] = nil
        end
    end

    for key, job in pairs(self.deferredJobs) do
        if not wanted[key] then
            self.deferredJobs[key] = nil
        end
    end

    self:_processDeferredJobs(now, wanted)
    self:_dispatchQueuedJobs()

        for key, marker in pairs(self.activeChunks) do
            if not wanted[key] then
                requestUnloadOnManager(key)
                if marker.Parent then
                    marker:Destroy()
                end
                self.activeChunks[key] = nil
                self.chunkLOD[key] = nil
                self.pending[key] = nil
                self.pendingLOD[key] = nil
                self.lastUpgrade[key] = nil
                self.bandMeta[key] = nil
                local cx, cz = key:match("^(-?%d+):%-?%d+:(-?%d+)")
                if cx and cz then
                    local k2d = cx .. ":" .. cz
                    if self.mountainTagged[k2d] then
                        self.mountainTagged[k2d] = nil
                    end
                end
                self:_releasePending(key)
                self:_removeStats(key)
                self.jobQueue[key] = nil
                self.deferredJobs[key] = nil
                if self.debugOverlay then
                self.debugOverlay:remove(key)
            end
        end
    end
end

function ChunkManager:updateAround(pos)
    local centerXZ: Vector2
    if typeof(pos) == "Vector3" then
        centerXZ = Vector2.new(pos.X, pos.Z)
    elseif typeof(pos) == "Vector2" then
        centerXZ = pos
    else
        local cam = workspace.CurrentCamera
        local p = (cam and cam.CFrame.Position) or Vector3.zero
        centerXZ = Vector2.new(p.X, p.Z)
    end
    self:step(centerXZ)
end

return ChunkManager
