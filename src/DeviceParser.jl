"""
DeviceParser.jl - Parse device hierarchy from measurement filenames
"""

using Dates

# ---------------------------------------------------------------------------
# Constants / Regex patterns
# ---------------------------------------------------------------------------
const MAX_HEADER_LINES = 50
const REGEX_DEVICE = r"RuO2test_([A-Z0-9]+)_([A-Z0-9]+)_([A-Z0-9]+(?:W[0-9]+)?)"

# ---------------------------------------------------------------------------
# DeviceInfo
# ---------------------------------------------------------------------------

struct DeviceInfo
    location::Vector{String}  # variable-length hierarchy
end

# ---------------------------------------------------------------------------
# Measurement related structs
# ---------------------------------------------------------------------------
struct MeasurementInfo
    filename::String
    filepath::String
    clean_title::String
    measurement_type::String
    timestamp::Union{DateTime,Nothing}
    device_info::DeviceInfo
    parameters::Dict{String,Any}
end

struct HierarchyNode
    name::String
    kind::Symbol
    children::Vector{HierarchyNode}
    measurements::Vector{MeasurementInfo}
end

struct MeasurementHierarchy
    root::HierarchyNode
    all_measurements::Vector{MeasurementInfo}
    root_path::String
    index::Dict{Tuple{Vararg{String}},HierarchyNode}
end

HierarchyNode(name::String, kind::Symbol) = HierarchyNode(name, kind, HierarchyNode[], MeasurementInfo[])

# ---------------------------------------------------------------------------
# Parsing helpers
# ---------------------------------------------------------------------------

function MeasurementInfo(filepath::AbstractString)
    filename = basename(filepath)
    device_info = parse_device_info(filename)
    measurement_type = parse_measurement_type(filename)
    timestamp = parse_timestamp(filename)
    parameters = parse_parameters(filename)
    file_info = extract_file_info(filepath)
    exp_label = measurement_type
    device_label = (m = match(REGEX_DEVICE, filename)) !== nothing ? join(m.captures, "_") : ""
    date_str = let d = get(file_info, "test_date", "")
        isempty(d) && return ""
        try
            parts = split(d)
            if length(parts) >= 3
                month = parts[2]
                day = try
                    parse(Int, parts[3])
                catch
                    return d
                end
                "$(month)$(day)"
            else
                d
            end
        catch
            d
        end
    end
    parts = filter(!isempty, (exp_label == "Unknown" ? "" : exp_label, device_label, date_str))
    clean_title = isempty(parts) ? strip(replace(filename, r"\.csv$" => "")) : join(parts, " ")
    return MeasurementInfo(filename, filepath, clean_title, measurement_type, timestamp, device_info, parameters)
end

function extract_file_info(path::AbstractString)
    file_stat = stat(path)
    size_bytes = file_stat.size
    setup_title = test_date = test_time = device_id = ""
    line_count = 0
    open(path, "r") do io
        for line in eachline(io)
            line_count += 1
            if startswith(line, "Setup title,")
                parts = split(line, ',')
                if length(parts) > 1
                    setup_title = strip(parts[2], '"')
                end
            elseif startswith(line, "Test date,")
                parts = split(line, ',')
                length(parts) > 1 && (test_date = parts[2])
            elseif startswith(line, "Test time,")
                parts = split(line, ',')
                length(parts) > 1 && (test_time = parts[2])
            elseif startswith(line, "Device ID,")
                parts = split(line, ',')
                device_id = length(parts) > 1 ? parts[2] : ""
            end
            line_count >= MAX_HEADER_LINES && break
        end
    end
    return Dict(
        "setup_title" => setup_title,
        "test_date" => test_date,
        "test_time" => test_time,
        "device_id" => device_id,
        "size_bytes" => size_bytes,
    )
end

function parse_device_info(filename::String)
    if (m = match(REGEX_DEVICE, filename)) !== nothing
        return DeviceInfo(collect(m.captures))
    end
    return DeviceInfo(["Unknown"])
end

function parse_measurement_type(filename::String)
    filename_lower = lowercase(filename)
    if contains(filename_lower, "fe pund") || contains(filename_lower, "fepund")
        return "FE PUND"
    elseif contains(filename_lower, "i_v sweep") || contains(filename_lower, "iv sweep")
        return "I-V Sweep"
    elseif contains(filename_lower, "tlm_4p") || contains(filename_lower, "tlm")
        return "TLM 4-Point"
    elseif contains(filename_lower, "break") || contains(filename_lower, "breakdown")
        return "Breakdown"
    elseif contains(filename_lower, "wakeup")
        return "Wakeup"
    else
        return "Unknown"
    end
end

function parse_timestamp(filename::String)
    if (m = match(r"; (\d{4}-\d{2}-\d{2}) (\d{2})_(\d{2})_(\d{2})\]", filename)) !== nothing
        date_str, hour, minute, second = m.captures
        try
            return DateTime("$date_str $hour:$minute:$second", "yyyy-mm-dd HH:MM:SS")
        catch
            return nothing
        end
    end
    return nothing
end

function parse_parameters(filename::String)
    params = Dict{String,Any}()
    if (m = match(r"(\d+(?:\.\d+)?)V", filename)) !== nothing
        params["voltage_V"] = parse(Float64, m.captures[1])
    end
    if (m = match(r"(\d+(?:\.\d+)?)(kHz|Hz)", lowercase(filename))) !== nothing
        val = parse(Float64, m.captures[1])
        unit = m.captures[2]
        params["frequency_hz"] = unit == "khz" ? val * 1e3 : val
    end
    if (m = match(r"\((\d+)\)", filename)) !== nothing
        params["count"] = parse(Int, m.captures[1])
    end
    return params
end

function meas_id(meas::MeasurementInfo)
    return "$(meas.timestamp) $(meas.measurement_type)"
end

# ---------------------------------------------------------------------------
# Multi-device (Breakdown) expansion
# ---------------------------------------------------------------------------
function expand_multi_device(meas::MeasurementInfo)::Vector{MeasurementInfo}
    meas.measurement_type == "Breakdown" || return [meas]
    dev = last(meas.device_info.location)
    if (m = match(r"^([A-Z][1-9]+)([A-Z][1-9]+)$", dev)) === nothing
        return [meas]
    end
    parts = m.captures
    loc = copy(meas.device_info.location)
    return [MeasurementInfo(
        meas.filename,
        meas.filepath,
        replace(meas.clean_title, dev => p),
        meas.measurement_type,
        meas.timestamp,
        DeviceInfo(vcat(loc[1:end-1], [p])),
        deepcopy(meas.parameters),
    ) for p in parts]
end

# ---------------------------------------------------------------------------
# Sorting helpers
# ---------------------------------------------------------------------------
function roman_value(s::AbstractString)
    ROMAN_MAP = Dict('I' => 1, 'V' => 5, 'X' => 10, 'L' => 50)
    isempty(s) && return nothing
    total = 0
    prev = 0
    for c in reverse(uppercase(s))
        v = get(ROMAN_MAP, c, 0)
        v == 0 && return nothing
        if v < prev
            total -= v
        else
            total += v
            prev = v
        end
    end
    return total
end

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

function Base.sort!(node::HierarchyNode)
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
        sort!(node.children, by=c -> roman_value(c.name))
    else
        sort!(node.children, by=c -> natural_key(c.name))
    end
    for ch in node.children
        sort!(ch.measurements, by=m -> m.timestamp === nothing ? DateTime(typemax(Date).year) : m.timestamp)
    end
    return node
end

function Base.sort!(mh::MeasurementHierarchy)
    sort!(mh.root)
    return mh
end

# ---------------------------------------------------------------------------
# Hierarchy construction
# ---------------------------------------------------------------------------
function MeasurementHierarchy(measurements::Vector{MeasurementInfo}, root_path::String)
    root = HierarchyNode("/", :root)
    index = Dict{Tuple{Vararg{String}},HierarchyNode}()
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
        segs = m.device_info.location
        parent = root
        for (i, seg) in enumerate(segs)
            kind = i == length(segs) ? :leaf : :level
            path_tuple = Tuple(segs[1:i])
            parent = ensure_child(parent, seg, kind, path_tuple)
        end
        push!(parent.measurements, m)
    end
    mh = MeasurementHierarchy(root, measurements, root_path, index)
    sort!(mh)
    return mh
end

children(node::HierarchyNode) = node.children
isleaf(node::HierarchyNode) = isempty(node.children)

# ---------------------------------------------------------------------------
# Scanning
# ---------------------------------------------------------------------------
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
                    @warn "Could not parse measurement file $filepath" error = e
                end
            end
        end
    end
    return MeasurementHierarchy(measurements, root_path)
end

"""
Get statistics about a set of measurements.
"""
function get_device_stats(measurements::Vector{MeasurementInfo})
    stats = Dict{String,Any}()
    stats["total_measurements"] = length(measurements)
    stats["measurement_types"] = unique([m.measurement_type for m in measurements])
    timestamps = [m.timestamp for m in measurements if m.timestamp !== nothing]
    if !isempty(timestamps)
        stats["first_measurement"] = minimum(timestamps)
        stats["last_measurement"] = maximum(timestamps)
    end
    all_params = Dict{String,Vector{Any}}()
    for measurement in measurements
        for (key, value) in measurement.parameters
            if !haskey(all_params, key)
                all_params[key] = Any[]
            end
            push!(all_params[key], value)
        end
    end
    stats["parameter_ranges"] = Dict{String,Any}()
    for (param, values) in all_params
        if eltype(values) <: Number && !isempty(values)
            stats["parameter_ranges"][param] = (minimum(values), maximum(values))
        end
    end
    return stats
end
