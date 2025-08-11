"""
MeasurementData.jl - Data structures and scanning functionality
"""

using DataFrames
using Dates

# DeviceParser types and functions are already included in main module

# Generic hierarchical data structure ---------------------------------------
struct HierarchyNode
    name::String
    kind::Symbol
    children::Vector{HierarchyNode}
    measurements::Vector{MeasurementInfo}
end

HierarchyNode(name::String, kind::Symbol) = HierarchyNode(name, kind, HierarchyNode[], MeasurementInfo[])

struct MeasurementHierarchy
    root::HierarchyNode
    all_measurements::Vector{MeasurementInfo}
    root_path::String
    index::Dict{Tuple{Vararg{String}}, HierarchyNode}
end

# ---------------------------------------------------------------------------
# Sorting helpers (generic, reusable)
# ---------------------------------------------------------------------------
function roman_value(s::AbstractString)
    ROMAN_MAP = Dict('I'=>1,'V'=>5,'X'=>10,'L'=>50)
    isempty(s) && return nothing
    total = 0; prev = 0
    for c in reverse(uppercase(s))
        v = get(ROMAN_MAP, c, 0); v == 0 && return nothing
        if v < prev; total -= v else total += v; prev = v end
    end
    return total
end

# Natural alphanumeric split key
function natural_key(s::AbstractString)
    toks = eachmatch(r"\d+|\D+", String(s))
    parts = Any[]
    for t in toks
        seg = t.match
        if all(isdigit, seg)
            push!(parts, (1, parse(Int, seg)))
        else
            push!(parts, (0, lowercase(seg)))
        end
    end
    return Tuple(parts)
end


# sort! for a single node (recursive)
function Base.sort!(node::HierarchyNode)
    # Decide if a vector of nodes should use Roman sorting (all valid romans)
    function _roman_sortable(children::Vector{HierarchyNode})
        isempty(children) && return false
        for ch in children
            roman_value(ch.name) === nothing && return false
        end
        return true
    end

    for ch in node.children
        sort!(ch)
    end
    if _roman_sortable(node.children)
        sort!(node.children, by = c -> roman_value(c.name))
    else
        sort!(node.children, by = c -> natural_key(c.name))
    end
    # Sort measurements chronologically
    for ch in node.children
        sort!(ch.measurements, by = m -> m.timestamp === nothing ? DateTime(typemax(Date).year) : m.timestamp)
    end
    return node
end

# sort! for whole hierarchy
function Base.sort!(mh::MeasurementHierarchy)
    sort!(mh.root)
    return mh
end

# ---------------------------------------------------------------------------
# Constructor building unsorted tree then sorting via sort!
# ---------------------------------------------------------------------------
function MeasurementHierarchy(measurements::Vector{MeasurementInfo}, root_path::String)
    root = HierarchyNode("/", :root)
    index = Dict{Tuple{Vararg{String}}, HierarchyNode}()
    function ensure_child(parent::HierarchyNode, name::String, kind::Symbol, path_tuple::Tuple{Vararg{String}})
        for ch in parent.children
            if ch.name == name
                return ch
            end
        end
        node = HierarchyNode(name, kind)
        push!(parent.children, node)
        index[path_tuple] = node
        return node
    end
    for m in measurements
        chip = m.device_info.chip
        sub = m.device_info.subsite
        dev = m.device_info.device
        chip_node = ensure_child(root, chip, :level1, (chip,))
        sub_node = ensure_child(chip_node, sub, :level2, (chip, sub))
        dev_node = ensure_child(sub_node, dev, :leaf, (chip, sub, dev))
        push!(dev_node.measurements, m)
    end
    mh = MeasurementHierarchy(root, measurements, root_path, index)
    sort!(mh)
    return mh
end

# Provide iteration utilities
children(node::HierarchyNode) = node.children
isleaf(node::HierarchyNode) = isempty(node.children)

"""
Scan directory recursively for measurement files with enhanced analysis
"""
function scan_directory(root_path::String)::MeasurementHierarchy
    measurements = MeasurementInfo[]
    for (root, dirs, files) in walkdir(root_path)
        for file in files
            if endswith(lowercase(file), ".csv")
                filepath = joinpath(root, file)
                try
                    measurement_info = MeasurementInfo(filepath)
                    for m in expand_multi_device(measurement_info)
                        push!(measurements, m)
                    end
                catch e
                    @warn "Could not parse measurement file $filepath" error=e
                end
            end
        end
    end
    return MeasurementHierarchy(measurements, root_path)
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
