"""
DeviceParser.jl - Parse device hierarchy from measurement filenames
"""

using Dates

# ---------------------------------------------------------------------------
# Constants / Regex patterns
# ---------------------------------------------------------------------------
const MAX_HEADER_LINES = 50
const REGEX_DEVICE = r"RuO2test_([A-Z0-9]+)_([A-Z0-9]+)_([A-Z0-9]+(?:W[0-9]+)?)"

struct DeviceInfo
    chip::String
    subsite::String
    device::String
    full_path::String
end

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

"Generic hierarchical data structure"
struct MeasurementHierarchy
    root::HierarchyNode
    all_measurements::Vector{MeasurementInfo}
    root_path::String
    index::Dict{Tuple{Vararg{String}},HierarchyNode}
end

# Convenience constructor for HierarchyNode
HierarchyNode(name::String, kind::Symbol) = HierarchyNode(name, kind, HierarchyNode[], MeasurementInfo[])

# Convenience constructor: derive all metadata (including clean title) from a filepath
function MeasurementInfo(filepath::AbstractString)
    filename = basename(filepath)
    device_info = parse_device_info(filename)
    measurement_type = parse_measurement_type(filename)
    timestamp = parse_timestamp(filename)
    parameters = parse_parameters(filename)
    file_info = extract_file_info(filepath)
    exp_label = measurement_type
    # Device identifier reuse same regex
    device = if (m = match(REGEX_DEVICE, filename)) !== nothing
        "RuO2test_$(join(m.captures, "_"))"
    else
        ""
    end
    date_str = let d = get(file_info, "test_date", "")
        isempty(d) && return ""
        try
            parts = split(d)
            if length(parts) >= 3
                month = parts[2]
                day = try
                    parse(Int, parts[3])
                catch err
                    return d
                end
                "$(month)$(day)"
            else
                d
            end
        catch err
            d
        end
    end
    parts = filter(!isempty, (exp_label == "Unknown" ? "" : exp_label, device, date_str))
    clean_title = isempty(parts) ? strip(replace(filename, r"\.csv$" => "")) : join(parts, " ")
    return MeasurementInfo(filename, filepath, clean_title, measurement_type, timestamp, device_info, parameters)
end

"File header extraction (stream first N lines only)"
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
        # total_lines omitted (expensive); could be added with a separate pass if needed
    )
end

"""
Parse device information from filename
Examples:
- "RuO2test_A2_VII_B6(1)" -> chip="A2", subsite="VII", device="B6"
- "RuO2test_A2_XI_TLML800W2(1)" -> chip="A2", subsite="XI", device="TLML800W2"
"""
function parse_device_info(filename::String)
    if (m = match(REGEX_DEVICE, filename)) !== nothing
        chip, subsite, device = m.captures
        return DeviceInfo(chip, subsite, device, "$(chip)/$(subsite)/$(device)")
    end
    return DeviceInfo("Unknown", "Unknown", "Unknown", "Unknown/Unknown/Unknown")
end

"""
Extract measurement type from filename
"""
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

"""
Extract timestamp from filename
"""
function parse_timestamp(filename::String)
    if (m = match(r"; (\d{4}-\d{2}-\d{2}) (\d{2})_(\d{2})_(\d{2})\]", filename)) !== nothing
        date_str, hour, minute, second = m.captures
        # Pattern assures validity; keep a defensive try in case of unexpected values
        try
            return DateTime("$date_str $hour:$minute:$second", "yyyy-mm-dd HH:MM:SS")
        catch
            return nothing
        end
    end
    return nothing
end

"""
Extract measurement parameters from filename
"""
function parse_parameters(filename::String)
    params = Dict{String,Any}()
    # Voltage (e.g., 1.2V)
    if (m = match(r"(\d+(?:\.\d+)?)V", filename)) !== nothing
        params["voltage_V"] = parse(Float64, m.captures[1])
    end
    # Frequency (Hz / kHz) normalize to Hz
    if (m = match(r"(\d+(?:\.\d+)?)(kHz|Hz)", lowercase(filename))) !== nothing
        val = parse(Float64, m.captures[1])
        unit = m.captures[2]
        params["frequency_hz"] = unit == "khz" ? val * 1e3 : val
    end
    # Count number (e.g., (3))
    if (m = match(r"\((\d+)\)", filename)) !== nothing
        params["count"] = parse(Int, m.captures[1])
    end
    return params
end

# Lightweight measurement identifier (kept for backwards compatibility)
function meas_id(meas::MeasurementInfo)
    return "$(meas.timestamp) $(meas.measurement_type)"
end

# ---------------------------------------------------------------------------
# Multi-device (Breakdown) expansion
# ---------------------------------------------------------------------------
"""
Expand a MeasurementInfo into multiple entries if it corresponds to a Breakdown
measurement that targeted multiple simple devices simultaneously.

Pattern handled: a device field like "D1D3" whose device component matches the regex
  ^([A-Z][1-9]+)([A-Z][1-9]+)
Meaning: two concatenated simple IDs (Letter + non-zero digit sequence). We split
into the two constituent IDs (e.g. D1 and D3), not treat it as a single device.
Only applied when measurement_type == "Breakdown" to avoid mis-parsing legitimate
single device names (e.g. TLML800W2).
"""
function expand_multi_device(meas::MeasurementInfo)::Vector{MeasurementInfo}
    # Fast path: only Breakdown measurements are candidates
    meas.measurement_type == "Breakdown" || return [meas]
    dev = meas.device_info.device
    # Match exactly two simple device tokens concatenated: Letter + non-zero digits (one or more)
    if (m = match(r"^([A-Z][1-9]+)([A-Z][1-9]+)$", dev)) === nothing
        return [meas]
    end
    parts = m.captures
    # Produce a new MeasurementInfo per constituent device
    return [MeasurementInfo(
        meas.filename,
        meas.filepath,
        replace(meas.clean_title, dev => p),  # update display title
        meas.measurement_type,
        meas.timestamp,
        DeviceInfo(
            meas.device_info.chip,
            meas.device_info.subsite,
            p,
            "$(meas.device_info.chip)/$(meas.device_info.subsite)/$(p)"
        ),
        deepcopy(meas.parameters),
    ) for p in parts]
end


# ---------------------------------------------------------------------------
# Sorting helpers (generic, reusable)
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
        sort!(node.children, by=c -> roman_value(c.name))
    else
        sort!(node.children, by=c -> natural_key(c.name))
    end
    # Sort measurements chronologically
    for ch in node.children
        sort!(ch.measurements, by=m -> m.timestamp === nothing ? DateTime(typemax(Date).year) : m.timestamp)
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
                    @warn "Could not parse measurement file $filepath" error = e
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
    stats = Dict{String,Any}()

    stats["total_measurements"] = length(measurements)
    stats["measurement_types"] = unique([m.measurement_type for m in measurements])

    # Time range
    timestamps = [m.timestamp for m in measurements if m.timestamp !== nothing]
    if !isempty(timestamps)
        stats["first_measurement"] = minimum(timestamps)
        stats["last_measurement"] = maximum(timestamps)
    end

    # Parameter ranges
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

"""
Filter measurements by criteria
"""
function filter_measurements(measurements::Vector{MeasurementInfo};
    measurement_type::Union{String,Nothing}=nothing,
    date_range::Union{Tuple{DateTime,DateTime},Nothing}=nothing,
    parameter_filters::Dict{String,Any}=Dict())

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
