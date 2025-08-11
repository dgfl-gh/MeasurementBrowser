"""
MeasurementData.jl - Data structures and scanning functionality
"""

using DataFrames
using Dates

# DeviceParser types and functions are already included in main module

struct DeviceHierarchy
    chips::Dict{String, Dict{String, Dict{String, Vector{MeasurementInfo}}}}
    all_measurements::Vector{MeasurementInfo}
    root_path::String
end

"""
Scan directory recursively for measurement files with enhanced analysis
"""
function scan_directory(root_path::String)::DeviceHierarchy
    measurements = MeasurementInfo[]
    
    # Walk through all subdirectories
    for (root, dirs, files) in walkdir(root_path)
        for file in files
            # Only process CSV files (measurement data)
            if endswith(lowercase(file), ".csv")
                filepath = joinpath(root, file)
                
                # Use basic file info extraction for now
                try
                    relative_dir = relpath(root, root_path)
                    measurement_info = MeasurementInfo(filepath)
                    # Expand potential multi-device breakdowns
                    for m in expand_multi_device(measurement_info)
                        push!(measurements, m)
                    end
                catch e
                    @warn "Could not parse measurement file $filepath" error=e
                    # Create a basic measurement info
                    relative_dir = relpath(root, root_path)
                    measurement_info = MeasurementInfo(
                        file,
                        filepath,
                        "Unknown Measurement",
                        "Unknown",
                        nothing,
                        DeviceInfo("Unknown", "Unknown", "Unknown", "N/A"),
                        Dict{String, Any}()
                    )
                    push!(measurements, measurement_info)
                end
            end
        end
    end
    
    # Build device hierarchy
    hierarchy = build_device_hierarchy(measurements, root_path)
    
    return hierarchy
end

"""
Build hierarchical device structure from measurements
"""
function build_device_hierarchy(measurements::Vector{MeasurementInfo}, root_path::String)
    chips = Dict{String, Dict{String, Dict{String, Vector{MeasurementInfo}}}}()
    
    for measurement in measurements
        chip = measurement.device_info.chip
        subsite = measurement.device_info.subsite
        device = measurement.device_info.device
        
        # Create nested structure
        if !haskey(chips, chip)
            chips[chip] = Dict{String, Dict{String, Vector{MeasurementInfo}}}()
        end
        
        if !haskey(chips[chip], subsite)
            chips[chip][subsite] = Dict{String, Vector{MeasurementInfo}}()
        end
        
        if !haskey(chips[chip][subsite], device)
            chips[chip][subsite][device] = MeasurementInfo[]
        end
        
        push!(chips[chip][subsite][device], measurement)
    end
    
    # Sort measurements within each device by timestamp
    for chip in values(chips)
        for subsite in values(chip)
            for device_measurements in values(subsite)
                sort!(device_measurements, by = m -> m.timestamp === nothing ? DateTime(2099) : m.timestamp)
            end
        end
    end
    
    return DeviceHierarchy(chips, measurements, root_path)
end

"""
Get statistics for a device (all measurements)
"""
function get_device_stats(measurements::Vector{MeasurementInfo})
    stats = Dict{String, Any}()
    
    stats["total_measurements"] = length(measurements)
    stats["measurement_types"] = unique([m.measurement_type for m in measurements])
    
    # Time range
    timestamps = [m.timestamp for m in measurements if m.timestamp !== nothing]
    if !isempty(timestamps)
        stats["first_measurement"] = minimum(timestamps)
        stats["last_measurement"] = maximum(timestamps)
        stats["duration"] = maximum(timestamps) - minimum(timestamps)
    end
    
    # Parameter ranges
    all_params = Dict{String, Vector{Any}}()
    for measurement in measurements
        for (key, value) in measurement.parameters
            if !haskey(all_params, key)
                all_params[key] = Any[]
            end
            push!(all_params[key], value)
        end
    end
    
    stats["parameter_ranges"] = Dict{String, Any}()
    for (param, values) in all_params
        if eltype(values) <: Number && !isempty(values)
            stats["parameter_ranges"][param] = (minimum(values), maximum(values))
        end
    end
    
    return stats
end

"""
Filter measurements by criteria
"""
function filter_measurements(measurements::Vector{MeasurementInfo}; 
                           measurement_type::Union{String, Nothing} = nothing,
                           date_range::Union{Tuple{DateTime, DateTime}, Nothing} = nothing,
                           parameter_filters::Dict{String, Any} = Dict())
    
    filtered = measurements
    
    # Filter by measurement type
    if measurement_type !== nothing
        filtered = filter(m -> m.measurement_type == measurement_type, filtered)
    end
    
    # Filter by date range
    if date_range !== nothing
        start_date, end_date = date_range
        filtered = filter(m -> m.timestamp !== nothing && 
                             start_date <= m.timestamp <= end_date, filtered)
    end
    
    # Filter by parameters
    for (param, criteria) in parameter_filters
        if isa(criteria, Tuple) && length(criteria) == 2  # Range filter
            min_val, max_val = criteria
            filtered = filter(m -> haskey(m.parameters, param) && 
                                 min_val <= m.parameters[param] <= max_val, filtered)
        else  # Exact match
            filtered = filter(m -> haskey(m.parameters, param) && 
                                 m.parameters[param] == criteria, filtered)
        end
    end
    
    return filtered
end
