module MeasurementBrowser

using Bonito
using WGLMakie
using DataFrames
using Dates
using JSON3
using Statistics
using Observables

# Core modules
include("DeviceParser.jl")
include("MeasurementData.jl")
include("PlotGenerator.jl")
include("BonitoInterface.jl")

# Re-export main functions
export start_browser, create_app, scan_directory, DeviceHierarchy

end # module MeasurementBrowser
