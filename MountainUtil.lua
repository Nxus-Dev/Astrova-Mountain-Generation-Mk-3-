
--!strict

local MountainConfig = require(script.Parent.MountainConfig)

export type BandPlan = {
    key: string,
    cx: number,
    cy: number,
    cz: number,
    tileId: number,
    lodIdx: number,
    factor: number,
    origin: Vector3,
    dims: Vector3int16,
    mountain: {
        bandIndex: number,
        bandName: string,
        maskStrength: number,
        topY: number,
        bottomY: number,
    },
    estimatedTris: number,
    estimatedVerts: number,
    priority: number,
}

local MountainUtil = {}

local MASK_CFG = MountainConfig.Mask
local HEIGHT_CFG = MountainConfig.Height
local MESH_CAPS = MountainConfig.MeshCaps or {}

local TRI_CAP = MESH_CAPS.MaxTriangles or math.huge
local VERT_CAP = MESH_CAPS.MaxVertices or math.huge
local SEGMENT_OVERLAP_CELLS = math.max(0, math.floor(MESH_CAPS.SegmentOverlapCells or 0))

local FBM_AMP = 4.0
local FBM_FREQ = 0.02
local FBM_GAIN = 0.5
local FBM_OCT = 3

local HILL_SPACING = 420.0
local HILL_RADIUS = 120.0
local HILL_HEIGHT = 28.0
local HILL_CHANCE = 0.6

local function randCell(ix: number, iz: number, sx: number, sz: number): number
    return 0.5 + 0.5 * math.noise(ix * 12.9898 + sx, 0, iz * 78.233 + sz)
end

local function fbm2(x: number, z: number, freq: number, gain: number, octaves: number): number
    local a = 0.0
    local f = freq
    local amp = 1.0
    for _ = 1, octaves do
        a += math.noise(x * f, 0, z * f) * amp
        f *= 2.0
        amp *= gain
    end
    return a
end

local function hillBump(x: number, z: number): number
    local ix = math.floor(x / HILL_SPACING)
    local iz = math.floor(z / HILL_SPACING)
    if randCell(ix, iz, 11.1, 22.2) <= (1.0 - HILL_CHANCE) then
        return 0.0
    end
    local jx = randCell(ix, iz, 33.3, 44.4)
    local jz = randCell(ix, iz, 55.5, 66.6)
    local cx = (ix + jx) * HILL_SPACING
    local cz = (iz + jz) * HILL_SPACING
    local dx = x - cx
    local dz = z - cz
    local dist = math.sqrt(dx * dx + dz * dz)
    if dist >= HILL_RADIUS then
        return 0.0
    end
    local t = 1.0 - dist / HILL_RADIUS
    local smooth = t * t * (3.0 - 2.0 * t)
    return smooth * HILL_HEIGHT
end

function MountainUtil.baseHeight(x: number, z: number, baseY: number): number
    local base = baseY + fbm2(x, z, FBM_FREQ, FBM_GAIN, FBM_OCT) * FBM_AMP
    local bump = hillBump(x, z)
    return base + bump
end

local function ridgedFbm(x: number, z: number): number
    local freq = HEIGHT_CFG.RidgeFrequency
    local amp = 1.0
    local gain = HEIGHT_CFG.RidgeGain
    local lacunarity = HEIGHT_CFG.RidgeLacunarity
    local sharp = math.max(0.01, HEIGHT_CFG.RidgeSharpness)
    local total = 0.0
    local weight = 1.0
    for _ = 1, HEIGHT_CFG.RidgeOctaves do
        local n = math.noise(x * freq, 0, z * freq)
        n = 1.0 - math.abs(n)
        n *= n
        n *= weight
        total += n * amp
        weight = math.clamp(n * sharp, 0.0, 1.0)
        freq *= lacunarity
        amp *= gain
    end
    return total
end

function MountainUtil.maskValue(x: number, z: number): number
    local freq = MASK_CFG.Frequency
    local amp = 1.0
    local gain = MASK_CFG.Gain
    local total = 0.0
    local lacunarity = 2.13
    for _ = 1, MASK_CFG.Octaves do
        local nx = x * freq + MountainConfig.Seed * 0.0017
        local nz = z * freq + MountainConfig.Seed * 0.0031
        total += math.noise(nx, 0, nz) * amp
        freq *= lacunarity
        amp *= gain
    end
    total = 0.5 + 0.5 * total
    local width = math.max(0.001, MASK_CFG.BlendWidth)
    local normalized = math.clamp((total - MASK_CFG.Threshold) / width, 0.0, 1.0)
    return math.pow(normalized, MASK_CFG.Sharpness)
end

function MountainUtil.mountainProfile(x: number, z: number, baseY: number)
    local ground = MountainUtil.baseHeight(x, z, baseY)
    local mask = MountainUtil.maskValue(x, z)
    if mask <= 0.0 then
        return {
            mask = 0.0,
            height = ground,
            base = ground,
            peak = ground,
            bottom = ground - HEIGHT_CFG.FootDrop,
        }
    end
    local ridge = math.clamp(ridgedFbm(x, z), 0.0, 1.0)
    local ridgePow = math.pow(ridge, math.max(1.0, HEIGHT_CFG.SharpExponent))
    local extra = HEIGHT_CFG.BaseLift + HEIGHT_CFG.VerticalScale * ridgePow
    local peak = ground + extra
    local baseAdjusted = ground - HEIGHT_CFG.BaseSink * mask
    local blend = math.clamp(mask, 0.0, 1.0)
    local height = baseAdjusted + (peak - baseAdjusted) * math.pow(blend, 0.85)
    return {
        mask = mask,
        height = height,
        base = baseAdjusted,
        peak = peak,
        bottom = baseAdjusted - HEIGHT_CFG.FootDrop,
    }
end

function MountainUtil.heightRangeForChunk(cx: number, cz: number, chunkSize: number, baseY: number)
    local samples = 3
    local minY = math.huge
    local maxY = -math.huge
    local maxMask = 0.0
    for ix = 0, samples - 1 do
        for iz = 0, samples - 1 do
            local fx = (ix + 0.5) / samples
            local fz = (iz + 0.5) / samples
            local wx = (cx + fx) * chunkSize
            local wz = (cz + fz) * chunkSize
            local profile = MountainUtil.mountainProfile(wx, wz, baseY)
            minY = math.min(minY, profile.bottom)
            maxY = math.max(maxY, profile.peak)
            maxMask = math.max(maxMask, profile.mask)
        end
    end
    if minY == math.huge then
        minY = baseY
        maxY = baseY
    end
    return minY, maxY, maxMask
end

function MountainUtil.isMountainChunk(cx: number, cz: number, chunkSize: number, baseY: number): boolean
    local _, _, mask = MountainUtil.heightRangeForChunk(cx, cz, chunkSize, baseY)
    return mask > 0.01
end

local function bandHeightForLOD(bandCfg, lodIdx: number): number
    local map = bandCfg.LODHeights
    local height = map and map[lodIdx]
    if height ~= nil then
        return height
    end
    return bandCfg.HeightStuds
end

local function horizontalTileCount(lodIdx: number): number
    return MountainConfig.HorizontalTilesPerLOD[lodIdx] or 1
end

local function keyFor(cx: number, cy: number, cz: number, tileId: number, segmentIndex: number?): string
    if tileId > 0 then
        if segmentIndex and segmentIndex > 0 then
            return string.format("%d:%d:%d:%d:%d", cx, cy, cz, tileId, segmentIndex)
        end
        return string.format("%d:%d:%d:%d", cx, cy, cz, tileId)
    end
    return string.format("%d:%d:%d", cx, cy, cz)
end

local function estimateTrisForDims(x: number, y: number, z: number): number
    return x * y * z * 2
end

local function estimateVertsForDims(x: number, y: number, z: number): number
    return (x + 1) * (y + 1) * (z + 1)
end

local function applyEstimates(job)
    local dims = job.dims
    local x = dims.X
    local y = dims.Y
    local z = dims.Z
    job.estimatedTris = estimateTrisForDims(x, y, z)
    job.estimatedVerts = estimateVertsForDims(x, y, z)
end

local function splitJobByCaps(job, voxelSize: number)
    applyEstimates(job)
    if job.estimatedTris <= TRI_CAP and job.estimatedVerts <= VERT_CAP then
        job.segmentIndex = 0
        job.tileSegment = 0
        if job.mountain then
            job.mountain.segmentIndex = 0
        end
        job.key = job.key or keyFor(job.cx, job.cy, job.cz, job.tileId)
        return { job }
    end

    local dims = job.dims
    local totalCellsY = math.max(1, dims.Y)
    local perLayerTris = dims.X * dims.Z * 2
    local perLayerVerts = (dims.X + 1) * (dims.Z + 1)
    if perLayerTris <= 0 or perLayerVerts <= 0 then
        job.segmentIndex = 0
        job.tileSegment = 0
        if job.mountain then
            job.mountain.segmentIndex = 0
        end
        job.key = job.key or keyFor(job.cx, job.cy, job.cz, job.tileId)
        return { job }
    end

    local maxCells = totalCellsY
    if TRI_CAP < math.huge then
        local limit = math.floor(TRI_CAP / perLayerTris)
        if limit >= 1 then
            maxCells = math.min(maxCells, limit)
        else
            maxCells = 1
        end
    end
    if VERT_CAP < math.huge then
        local denom = (dims.X + 1) * (dims.Z + 1)
        if denom > 0 then
            local limit = math.floor(VERT_CAP / denom) - 1
            if limit >= 1 then
                maxCells = math.min(maxCells, limit)
            else
                maxCells = 1
            end
        end
    end

    if maxCells >= totalCellsY then
        job.segmentIndex = 0
        job.tileSegment = 0
        if job.mountain then
            job.mountain.segmentIndex = 0
        end
        job.key = job.key or keyFor(job.cx, job.cy, job.cz, job.tileId)
        return { job }
    end

    maxCells = math.max(1, maxCells)
    local overlap = math.clamp(SEGMENT_OVERLAP_CELLS, 0, math.max(0, maxCells - 1))
    local stride = math.max(1, maxCells - overlap)

    local segments = {}
    local cursor = 0
    while cursor < totalCellsY do
        local topCell = math.min(totalCellsY, cursor + maxCells)
        local segCells = topCell - cursor
        if segCells <= 0 then
            break
        end
        local originY = job.origin.Y + cursor * voxelSize
        local subDims = Vector3int16.new(dims.X, math.max(1, segCells), dims.Z)
        local subJob = {
            cx = job.cx,
            cy = job.cy,
            cz = job.cz,
            tileId = job.tileId,
            lodIdx = job.lodIdx,
            factor = job.factor,
            origin = Vector3.new(job.origin.X, originY, job.origin.Z),
            dims = subDims,
            mountain = {
                bandIndex = job.mountain and job.mountain.bandIndex or 0,
                bandName = job.mountain and job.mountain.bandName or "",
                maskStrength = job.mountain and job.mountain.maskStrength or 0.0,
                topY = math.min(job.mountain and job.mountain.topY or (originY + segCells * voxelSize), originY + segCells * voxelSize),
                bottomY = math.max(job.mountain and job.mountain.bottomY or originY, originY),
            },
            priority = job.priority,
        }
        applyEstimates(subJob)
        segments[#segments + 1] = subJob
        if topCell >= totalCellsY then
            break
        end
        cursor += stride
    end

    table.sort(segments, function(a, b)
        return a.mountain.topY > b.mountain.topY
    end)

    if #segments <= 0 then
        job.segmentIndex = 0
        job.tileSegment = 0
        if job.mountain then
            job.mountain.segmentIndex = 0
        end
        job.key = job.key or keyFor(job.cx, job.cy, job.cz, job.tileId)
        return { job }
    end

    for index, seg in ipairs(segments) do
        local segIndex = index - 1
        seg.segmentIndex = segIndex
        seg.tileSegment = segIndex
        seg.key = keyFor(seg.cx, seg.cy, seg.cz, seg.tileId, segIndex)
        if seg.mountain then
            seg.mountain.segmentIndex = segIndex
        end
    end

    return segments
end

function MountainUtil.planBands(cx: number, cz: number, chunkSize: number, baseVoxel: number, baseCells: number, baseY: number, lodIdx: number, factor: number, mountainFactor: number, overlapCells: number, cooldown: number)
    local minY, maxY, maskStrength = MountainUtil.heightRangeForChunk(cx, cz, chunkSize, baseY)
    if maskStrength <= 0.0 then
        return {}, maskStrength
    end
    local bands = {}
    local tileCount = horizontalTileCount(lodIdx)
    local tileSpan = chunkSize / tileCount
    local adjustedFactor = factor * mountainFactor
    local cellsX = math.max(2, math.floor(baseCells / adjustedFactor + 0.5))
    local cellsZ = cellsX
    local vs = baseVoxel * adjustedFactor
    local currentTop = maxY
    for bandIndex, bandCfg in ipairs(MountainConfig.VerticalBands) do
        local bandHeightStuds = bandHeightForLOD(bandCfg, lodIdx)
        local bandBottom = currentTop - bandHeightStuds
        local overlapStuds = bandCfg.OverlapStuds or 0.0
        bandBottom += overlapStuds
        if bandBottom < minY then
            bandBottom = minY
        end
        local heightStuds = currentTop - bandBottom
        local cellsY = math.max(2, math.floor(heightStuds / vs + 0.5))
        local snappedBottom = math.floor(bandBottom / vs) * vs
        local snappedTop = snappedBottom + cellsY * vs
        currentTop = snappedBottom
        for tx = 0, tileCount - 1 do
            for tz = 0, tileCount - 1 do
                local tileId = bandIndex * 100 + tx * tileCount + tz
                local originX = (cx * chunkSize) + tx * tileSpan
                local originZ = (cz * chunkSize) + tz * tileSpan
                local tileCellsX = math.max(2, math.floor(cellsX / tileCount + 0.5))
                local tileCellsZ = tileCellsX
                local job = {
                    key = keyFor(cx, bandIndex, cz, tileId),
                    cx = cx,
                    cy = bandIndex,
                    cz = cz,
                    tileId = tileId,
                    lodIdx = lodIdx,
                    factor = adjustedFactor,
                    origin = Vector3.new(originX, snappedBottom, originZ),
                    dims = Vector3int16.new(tileCellsX, cellsY + overlapCells, tileCellsZ),
                    mountain = {
                        bandIndex = bandIndex,
                        bandName = bandCfg.Name,
                        maskStrength = maskStrength,
                        topY = snappedTop,
                        bottomY = snappedBottom,
                    },
                    estimatedTris = tileCellsX * (cellsY + overlapCells) * tileCellsZ * 2,
                    estimatedVerts = tileCellsX * (cellsY + overlapCells + 1) * tileCellsZ,
                    priority = MountainConfig.VerticalPriority[bandCfg.Name] or bandIndex,
                }
                local splitJobs = splitJobByCaps(job, vs)
                for _, subJob in ipairs(splitJobs) do
                    bands[#bands + 1] = subJob
                end
            end
        end
    end
    table.sort(bands, function(a, b)
        if a.mountain and b.mountain then
            if a.mountain.topY ~= b.mountain.topY then
                return a.mountain.topY > b.mountain.topY
            end
            local segA = a.mountain.segmentIndex or a.segmentIndex or 0
            local segB = b.mountain.segmentIndex or b.segmentIndex or 0
            if segA ~= segB then
                return segA < segB
            end
        end
        if a.priority ~= b.priority then
            return a.priority < b.priority
        end
        return a.key < b.key
    end)
    return bands, maskStrength
end

function MountainUtil.estimateCost(job: BandPlan)
    local tris = job.estimatedTris
    local verts = job.estimatedVerts
    return tris, verts
end

function MountainUtil.debugColorForBand(bandIndex: number): Color3?
    local cfg = MountainConfig.VerticalBands[bandIndex]
    return cfg and cfg.Color or nil
end

function MountainUtil.cooldownSeconds()
    return MountainConfig.CooldownSeconds or 0.0
end

function MountainUtil.config()
    return MountainConfig
end

return MountainUtil
