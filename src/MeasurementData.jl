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

# Remove separate natural_device_key / roman_value / subsite_key helpers and encapsulate logic in Base.sort

function Base.sort(dh::DeviceHierarchy)
    # Local helpers (kept private to this method)
    device_key(s::AbstractString) = begin
        if (m = match(r"^([A-Za-z]+)(\d+)$", String(s))) !== nothing
            return (m.captures[1], parse(Int, m.captures[2]))
        else
            return (String(s), 0)
        end
    end
    roman_value(s::AbstractString) = begin
        isempty(s) && return nothing
        # Simple limited roman numerals (I,V,X) sufficient for current subsites
        vals = Dict('I'=>1,'V'=>5,'X'=>10)
        total = 0; prev = 0
        for c in reverse(s)
            v = get(vals, c, 0); v == 0 && return nothing
            if v < prev; total -= v else total += v; prev = v end
        end
        total
    end
    subsite_key(s::AbstractString) = begin
        v = roman_value(s)
        v === nothing ? (1, String(s)) : (0, v)
    end

    new_chips = Dict{String, Dict{String, Dict{String, Vector{MeasurementInfo}}}}()
    for chip_key in sort(collect(keys(dh.chips)))
        subsites = dh.chips[chip_key]
        new_subsites = Dict{String, Dict{String, Vector{MeasurementInfo}}}()
        for subsite_key_name in sort(collect(keys(subsites)); by=subsite_key)
            devices = subsites[subsite_key_name]
            new_devices = Dict{String, Vector{MeasurementInfo}}()
            for device_key_name in sort(collect(keys(devices)); by=device_key)
                mvec = copy(devices[device_key_name])
                sort!(mvec, by = m -> m.timestamp === nothing ? DateTime(typemax(Date).year) : m.timestamp)
                new_devices[device_key_name] = mvec
            end
            new_subsites[subsite_key_name] = new_devices
        end
        new_chips[chip_key] = new_subsites
    end
    DeviceHierarchy(new_chips, dh.all_measurements, dh.root_path)
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

    # Return sorted hierarchy copy
    return sort(DeviceHierarchy(chips, measurements, root_path))
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
