
--!strict

local MountainConfig = require(script.Parent.MountainConfig)
local MountainUtil = require(script.Parent.MountainUtil)

export type OverlayUpdate = {
    key: string,
    center: Vector3,
    size: Vector3,
    bandIndex: number,
}

local MountainDebugOverlay = {}
MountainDebugOverlay.__index = MountainDebugOverlay

function MountainDebugOverlay.new()
    local cfg = MountainConfig.Debug
    if not (cfg and cfg.Enabled) then
        return setmetatable({
            enabled = false,
            parts = {},
        }, MountainDebugOverlay)
    end
    local folder = workspace:FindFirstChild(cfg.FolderName)
    if not folder then
        folder = Instance.new("Folder")
        folder.Name = cfg.FolderName or "MountainDebug"
        folder.Parent = workspace
    end
    local self = setmetatable({
        enabled = true,
        folder = folder,
        transparency = cfg.Transparency or 0.6,
        parts = {},
    }, MountainDebugOverlay)
    return self
end

function MountainDebugOverlay:update(info: OverlayUpdate)
    if not self.enabled then
        return
    end
    local part = self.parts[info.key]
    if not part then
        part = Instance.new("Part")
        part.Name = "MountainBand_" .. info.key
        part.Anchored = true
        part.CanCollide = false
        part.CanQuery = false
        part.CanTouch = false
        part.Material = Enum.Material.SmoothPlastic
        part.Transparency = self.transparency
        part.Parent = self.folder
        self.parts[info.key] = part
    end
    local color = MountainUtil.debugColorForBand(info.bandIndex) or Color3.fromRGB(180, 180, 180)
    part.Color = color
    part.Size = info.size
    part.CFrame = CFrame.new(info.center)
end

function MountainDebugOverlay:remove(key: string)
    local part = self.parts[key]
    if part then
        part:Destroy()
        self.parts[key] = nil
    end
end

function MountainDebugOverlay:clear()
    for key, part in pairs(self.parts) do
        if part then
            part:Destroy()
        end
        self.parts[key] = nil
    end
end

return MountainDebugOverlay
