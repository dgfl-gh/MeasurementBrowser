module MeasurementBrowser

# Core modules
include("DeviceParser.jl")
include("MeasurementData.jl")
include("RuO2Data.jl")
include("RuO2Plots.jl")
include("Gui.jl")

# Re-export main functions
export start_browser, scan_directory, MeasurementHierarchy, HierarchyNode
export MeasurementInfo, DeviceInfo, mark_dirty!

end # module MeasurementBrowser
