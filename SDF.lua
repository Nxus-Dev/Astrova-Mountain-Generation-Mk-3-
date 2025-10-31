
--!strict

local MountainUtil = require(script.Parent.MountainUtil)

local SDF = {}

function SDF.density(worldPos: Vector3, baseY: number)
    local profile = MountainUtil.mountainProfile(worldPos.X, worldPos.Z, baseY)
    local targetHeight = profile.height
    return worldPos.Y - targetHeight
end

return SDF
