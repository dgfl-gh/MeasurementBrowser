module MeasurementBrowser

# Core modules
include("DeviceParser.jl")
include("PlotGenerator.jl")
using .PlotGenerator
include("Gui.jl")

export start_browser, scan_directory
export MeasurementHierarchy, HierarchyNode, MeasurementInfo, DeviceInfo

end # module MeasurementBrowser
