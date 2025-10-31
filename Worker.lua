
-- Worker.lua ? parallel DC mesher (NO direct MeshPool usage)

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players           = game:GetService("Players")

local ModulesFolder = ReplicatedStorage:WaitForChild("Modules")

local DC  = require(ModulesFolder:WaitForChild("DualContouring"))
local SDF = require(ModulesFolder:WaitForChild("SDF"))
local MountainUtil = require(ModulesFolder:WaitForChild("MountainUtil"))

-- --- Config ---------------------------------------------------------
local GROUND_RAISE_VOX  = 2.0
-- Maintain single-sided output for all jobs to satisfy backface culling
-- requirements and avoid duplicate triangles.
local BASE_DOUBLE_SIDED = false

-- Solid debug colors per LOD.  Use bright, high-contrast hues so the
-- triangles are easier to see.  LOD 0 (nearest) uses bright red; LOD 1
-- uses bright green; LOD 2 and higher use bright blue.  Adjust these
-- values if you prefer different colors.
local LOD_COLORS = {
        [0] = Color3.fromRGB(255, 0,   0),   -- Bright red for crisp triangles
        [1] = Color3.fromRGB(0,   255, 0),   -- Bright green
        [2] = Color3.fromRGB(0,   0,   255), -- Bright blue
}

-- --- Manager Actor handle (the one that owns MeshPool) --------------
local function getManagerActor()
        local plr = Players.LocalPlayer
        if not plr then return nil end
        local ps = plr:WaitForChild("PlayerScripts")
        return ps:WaitForChild("MesherManagerActor") -- <== Actor
end

-- --- Chunk markers (so manager/manager queue can coordinate) --------
local function getChunkFolder()
        local f = workspace:FindFirstChild("ClientChunks")
        if not f then
                f = Instance.new("Folder")
                f.Name = "ClientChunks"
                f.Parent = workspace
        end
        return f
end

local function claimMarker(key: string, center: Vector3, nonce: number)
        local f = getChunkFolder()
        local v = f:FindFirstChild(key)
        if not v then
                v = Instance.new("BoolValue")
                v.Name = key
                v.Value = false
                v.Parent = f
        end
        v:SetAttribute("JobNonce", nonce)
        v:SetAttribute("Pending", true)
        pcall(function()
                v:SetAttribute("cx", center.X)
                v:SetAttribute("cy", center.Y)
                v:SetAttribute("cz", center.Z)
        end)
        return v
end

local function markerAliveWithNonce(key: string, nonce: number)
        local f = workspace:FindFirstChild("ClientChunks")
        if not f then return false end
        local v = f:FindFirstChild(key)
        if not v then return false end
        return v:GetAttribute("JobNonce") == nonce
end

-- --- DC wrapper -----------------------------------------------------
local function dcGenerate(origin: Vector3, voxelSize: number, nx: number, ny: number, nz: number, baseY: number)
        local function densityFn(p: Vector3)
                return SDF.density(p, baseY)
        end
        return DC.generate({
                origin      = origin,
                cellSize    = voxelSize,
                nx = nx, ny = ny, nz = nz,
                densityFn   = densityFn,
                snapStep    = 6e-4,
                signEps     = 0.01,
                halfOpenXZ  = true,
                closeY      = true,
        })
end

-- --- Worker inbox from ChunkManager --------------------------------
script.Parent:BindToMessage("generateMesh", function(payload)
        local key: string        = payload.Key
        local origin: Vector3    = payload.Origin
        local voxelSize: number  = payload.VoxelSize
        local baseVoxel: number  = payload.BaseVoxelSize
        local dims: Vector3int16 = payload.Dims
        local lodLevel: number   = payload.LODLevel or 0
        local mountainInfo = payload.Mountain
        local estimatedCost = payload.EstimatedCost
        local edgeLength = payload.EdgeLengthTarget
        local tileId = payload.TileId

        local nx, ny, nz = dims.X, dims.Y, dims.Z
        local baseY = (GROUND_RAISE_VOX or 2.0) * (baseVoxel or voxelSize)

        if mountainInfo then
                local segIndex = mountainInfo.SegmentIndex or 0
                print(string.format(
                        "[Worker][Mountain] job %s band=%d seg=%d tile=%s LOD=%d edge=%.2f",
                        tostring(key), mountainInfo.BandIndex or -1, segIndex, tostring(tileId), lodLevel, edgeLength or -1
                ))
        else
                print(string.format("[Worker][DC] job %s LOD=%d origin %d,%d,%d grid %dx%dx%d baseY=%.2f vx=%.2f",
                        tostring(key), lodLevel, origin.X, origin.Y, origin.Z, nx, ny, nz, baseY, voxelSize))
        end

        -- Create/claim a marker NOW with a unique nonce
        local nonce  = math.floor((os.clock() * 1000) % 2^31)
        local center = origin + Vector3.new(nx*voxelSize*0.5, 0, nz*voxelSize*0.5)
        claimMarker(key, center, nonce)

        -- Generate geometry
        local verts, tris = dcGenerate(origin, voxelSize, nx, ny, nz, baseY)

        -- If job is stale (manager replaced/cancelled marker), drop it
        if not markerAliveWithNonce(key, nonce) then
                print("[Worker] Dropped stale job for", key)
                return
        end

        -- If no geometry was produced, commit an empty chunk (unload) and finish.
        if (#verts == 0) or (#tris == 0) then
                local managerActor = getManagerActor()
                if managerActor then
                        managerActor:SendMessage("commitChunk", {
                                Key   = key,
                                Verts = {},
                                Tris  = {},
                                Opts  = {},
                                Nonce = nonce,
                        })
                else
                        warn("[Worker] No MesherManagerActor found; cannot commit", key)
                end
                return
        end

        -- Choose per-LOD solid color + shading hint.
        local predictedFlatVerts
        do
                local triPerFace = (BASE_DOUBLE_SIDED and (lodLevel <= 0)) and 6 or 3
                predictedFlatVerts = (#tris) * triPerFace
        end
        local useFlat = (lodLevel <= 0) and (predictedFlatVerts <= 55000)
        local solidColor
        if mountainInfo and mountainInfo.BandIndex then
                solidColor = MountainUtil.debugColorForBand(mountainInfo.BandIndex) or LOD_COLORS[lodLevel]
        else
                solidColor = LOD_COLORS[lodLevel]
        end
        solidColor = solidColor or LOD_COLORS[2]
        local flatShade  = useFlat

        -- Hand off to the manager Actor (the only place that touches MeshPool)
        local managerActor = getManagerActor()
        if not managerActor then
                warn("[Worker] No MesherManagerActor found; cannot commit", key)
                return
        end

        -- Choose target collision fidelity based on LOD.  For the nearest
        -- chunks (LOD0), request PreciseConvexDecomposition to generate the
        -- most accurate physics shape possible.  For mid and far LODs, fall
        -- back to less expensive fidelities to save memory and processing
        -- time.  These settings may be adjusted in ChunkManager by splitting
        -- LOD0 into smaller sub-chunks, so the total complexity remains
        -- manageable.
        local cfTarget
        if lodLevel <= 0 then
                cfTarget = Enum.CollisionFidelity.PreciseConvexDecomposition
        elseif lodLevel == 1 then
                cfTarget = Enum.CollisionFidelity.Default
        else
                cfTarget = Enum.CollisionFidelity.Hull
        end

        local stats = {
                Triangles = #tris,
                Vertices = #verts,
                EstimatedTris = estimatedCost and estimatedCost.Tris or 0,
                EstimatedVerts = estimatedCost and estimatedCost.Verts or 0,
                LOD = lodLevel,
                IsMountain = mountainInfo ~= nil,
                BandIndex = mountainInfo and mountainInfo.BandIndex or -1,
                SegmentIndex = mountainInfo and mountainInfo.SegmentIndex or 0,
                TileId = tileId,
        }

        managerActor:SendMessage("commitChunk", {
                Key   = key,
                Verts = verts,
                Tris  = tris,
                Opts  = {
                        DoubleSided     = BASE_DOUBLE_SIDED and (lodLevel <= 0),
                        UseVertexColors = false,        -- force solid per-face color
                        SolidColor      = solidColor,   -- LOD debug color
                        FlatShade       = flatShade,
                        CollisionFidelityTarget = cfTarget,
                },
                Nonce = nonce,
                Stats = stats,
                Mountain = mountainInfo,
        })
end)
