module MeasurementBrowser

# Core modules
include("DeviceParser.jl")
include("MeasurementData.jl")
include("PlotGenerator.jl")
include("BonitoInterface.jl")

# Re-export main functions
export start_browser, create_app, scan_directory, DeviceHierarchy

end # module MeasurementBrowser
