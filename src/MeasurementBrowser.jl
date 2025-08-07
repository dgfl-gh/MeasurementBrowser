module MeasurementBrowser

# Core modules
include("DeviceParser.jl")
include("MeasurementData.jl")
include("PlotGenerator.jl")
include("Gui.jl")

# Re-export main functions
export start_browser, scan_directory, DeviceHierarchy
export MeasurementInfo, DeviceInfo

end # module MeasurementBrowser
