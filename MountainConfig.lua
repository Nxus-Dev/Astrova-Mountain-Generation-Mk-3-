
--!strict

local MountainConfig = {
    Enabled = true,
    Seed = 91531,
    Mask = {
        Frequency = 0.0012,
        Octaves = 4,
        Gain = 0.48,
        Threshold = 0.38,
        BlendWidth = 0.18,
        Sharpness = 1.7,
    },
    Height = {
        BaseLift = 140.0,
        VerticalScale = 420.0,
        RidgeFrequency = 0.0035,
        RidgeOctaves = 4,
        RidgeGain = 0.46,
        RidgeLacunarity = 2.2,
        RidgeSharpness = 1.4,
        FootDrop = 36.0,
        BaseSink = 18.0,
        SharpExponent = 2.15,
    },
    VerticalBands = {
        {
            Name = "Summit",
            HeightStuds = 160.0,
            OverlapStuds = 20.0,
            Color = Color3.fromRGB(255, 98, 89),
            LODHeights = {
                [0] = 140.0,
                [1] = 120.0,
                [2] = 100.0,
                [3] = 80.0,
            },
        },
        {
            Name = "Mid",
            HeightStuds = 180.0,
            OverlapStuds = 22.0,
            Color = Color3.fromRGB(255, 170, 80),
            LODHeights = {
                [0] = 170.0,
                [1] = 150.0,
                [2] = 120.0,
                [3] = 90.0,
            },
        },
        {
            Name = "Base",
            HeightStuds = 200.0,
            OverlapStuds = 18.0,
            Color = Color3.fromRGB(180, 200, 255),
            LODHeights = {
                [0] = 200.0,
                [1] = 180.0,
                [2] = 140.0,
                [3] = 100.0,
            },
        },
    },
    HorizontalTilesPerLOD = {
        [0] = 2,
        [1] = 2,
        [2] = 1,
        [3] = 1,
    },
    BandOverlapCells = 2,
    Budget = {
        GlobalTriCap = 520000,
        GlobalVertCap = 780000,
        PressureThresholds = {
            Simplify = 0.78,
            SkipLowerBands = 0.9,
            Defer = 0.97,
        },
    },
    MeshCaps = {
        MaxTriangles = 18000,
        MaxVertices = 52000,
        SegmentOverlapCells = 1,
    },
    Simplification = {
        BaseEdgeLength = {
            [0] = 6.0,
            [1] = 9.0,
            [2] = 14.0,
            [3] = 18.0,
        },
        PressureFactor = 1.5,
    },
    MountainLodFactor = {
        [0] = 1.0,
        [1] = 1.2,
        [2] = 1.6,
        [3] = 2.0,
    },
    VerticalPriority = {
        Summit = 1,
        Mid = 2,
        Base = 3,
    },
    CooldownSeconds = 6.0,
    Debug = {
        Enabled = true,
        FolderName = "MountainDebug",
        Transparency = 0.6,
    },
}

function MountainConfig.get()
    return MountainConfig
end

return MountainConfig
