"""
DeviceParser.jl - Parse device hierarchy from measurement filenames
"""

using Dates

struct DeviceInfo
    chip::String
    subsite::String
    device::String
    full_path::String
end

struct MeasurementInfo
    filename::String
    filepath::String
    measurement_type::String
    timestamp::Union{DateTime, Nothing}
    device_info::DeviceInfo
    parameters::Dict{String, Any}
end

"""
Parse device information from filename
Examples:
- "RuO2test_A2_VII_B6(1)" -> chip="A2", subsite="VII", device="B6"
- "RuO2test_A2_XI_TLML800W2(1)" -> chip="A2", subsite="XI", device="TLML800W2"
"""
function parse_device_info(filename::String)
    # Try to match the RuO2test pattern
    pattern = r"RuO2test_([A-Z0-9]+)_([A-Z0-9]+)_([A-Z0-9]+(?:W[0-9]+)?)"
    m = match(pattern, filename)
    
    if m !== nothing
        chip, subsite, device = m.captures
        return DeviceInfo(chip, subsite, device, "$(chip)/$(subsite)/$(device)")
    end
    
    # Fallback patterns for other naming conventions
    # Add more patterns as needed
    
    # If no pattern matches, use generic parsing
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
    # Pattern: ; YYYY-MM-DD HH_MM_SS]
    pattern = r"; (\d{4}-\d{2}-\d{2}) (\d{2})_(\d{2})_(\d{2})\]"
    m = match(pattern, filename)
    
    if m !== nothing
        date_str, hour, minute, second = m.captures
        datetime_str = "$date_str $hour:$minute:$second"
        try
            return DateTime(datetime_str, "yyyy-mm-dd HH:MM:SS")
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
    params = Dict{String, Any}()
    
    # Extract voltage if present
    voltage_match = match(r"(\d+(?:\.\d+)?)V", filename)
    if voltage_match !== nothing
        params["voltage"] = parse(Float64, voltage_match.captures[1])
    end
    
    # Extract frequency if present
    freq_match = match(r"(\d+(?:\.\d+)?)\s*(?:kHz|Hz)", filename)
    if freq_match !== nothing
        params["frequency"] = parse(Float64, freq_match.captures[1])
    end
    
    # Extract sequence number
    seq_match = match(r"\((\d+)\)", filename)
    if seq_match !== nothing
        params["sequence"] = parse(Int, seq_match.captures[1])
    end
    
    return params
end

"""
Parse a measurement file and extract all information
"""
function parse_measurement_file(filepath::String, filename::String)
    device_info = parse_device_info(filename)
    measurement_type = parse_measurement_type(filename)
    timestamp = parse_timestamp(filename)
    parameters = parse_parameters(filename)
    
    return MeasurementInfo(
        filename,
        filepath,
        measurement_type,
        timestamp,
        device_info,
        parameters
    )
end
