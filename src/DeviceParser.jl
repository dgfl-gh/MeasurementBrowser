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

# ---------------------------------------------------------------------------
# File header extraction (stream first N lines only)
# ---------------------------------------------------------------------------
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
    # Sequence number (e.g., (3))
    if (m = match(r"\((\d+)\)", filename)) !== nothing
        params["sequence"] = parse(Int, m.captures[1])
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
