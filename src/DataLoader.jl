module DataLoader

using CSV
using DataFrames
using PrecompileTools: @setup_workload, @compile_workload

export find_files, get_file_patterns, read_iv_sweep, read_fe_pund, read_tlm_4p

"""
Find files matching a pattern in the specified directory
"""
function find_files(pattern, workdir=".")
    all_files = readdir(workdir)
    csv_files = filter(f -> endswith(f, ".csv"), all_files)
    return filter(f -> occursin(pattern, f), csv_files)
end


"""
Get standard file patterns for different measurement types
"""
function get_file_patterns()
    return (
        iv_sweep=r"I_V Sweep",
        fe_pund=r"FE PUND",
        tlm_4p=r"TLM_4P",
        breakdown=r"Break.*oxide",
        wakeup=r"Wakeup"
    )
end

"""
Read I-V sweep data from CSV file, skipping header metadata
"""
function read_iv_sweep(filename, workdir=".")
    filepath = joinpath(workdir, filename)
    lines = readlines(filepath)
    data_start = 1

    for (i, line) in enumerate(lines)
        if occursin(r"^-?\d+\.?\d*,-?\d+\.?\d*[eE]?-?\d*,-?\d+\.?\d*[eE]?-?\d*", line)
            data_start = i
            break
        end
    end

    data_lines = lines[data_start:end]
    voltage = Float64[]
    current1 = Float64[]
    current2 = Float64[]

    for line in data_lines
        if !isempty(strip(line))
            parts = split(line, ',')
            if length(parts) >= 3
                try
                    push!(voltage, parse(Float64, parts[1]))
                    push!(current1, parse(Float64, parts[2]))
                    push!(current2, parse(Float64, parts[3]))
                catch
                    continue
                end
            end
        end
    end

    return DataFrame(voltage=voltage, current1=current1, current2=current2)
end

"""
Read FE PUND data from CSV file
"""
function read_fe_pund(filename, workdir=".")
    filepath = joinpath(workdir, filename)
    lines = readlines(filepath)
    data_start = 1

    for (i, line) in enumerate(lines)
        if occursin("Time,MeasResult1_value,MeasResult2_value", line)
            data_start = i + 1
            break
        end
    end

    if data_start == 1
        return DataFrame()
    end

    data_lines = lines[data_start:end]
    time = Float64[]
    current = Float64[]
    voltage = Float64[]
    current_time = Float64[]
    voltage_time = Float64[]

    for line in data_lines
        if !isempty(strip(line))
            parts = split(line, ',')
            if length(parts) >= 5
                try
                    push!(time, parse(Float64, parts[1]))
                    push!(current, parse(Float64, parts[2]))
                    push!(voltage, parse(Float64, parts[3]))
                    push!(current_time, parse(Float64, parts[4]))
                    push!(voltage_time, parse(Float64, parts[5]))
                catch
                    continue
                end
            end
        end
    end

    return DataFrame(time=time, current=current, voltage=voltage,
        current_time=current_time, voltage_time=voltage_time)
end

"""
Read TLM 4-point data from CSV file
"""
function read_tlm_4p(filename, workdir=".")
    filepath = joinpath(workdir, filename)
    lines = readlines(filepath)
    data_start = 1

    for (i, line) in enumerate(lines)
        if occursin(r"^-?\d+\.?\d*[eE]?-?\d*,(-?\d+\.?\d*[eE]?-?\d*,){2,}", line)
            data_start = i
            break
        end
    end

    data_lines = lines[data_start:end]
    current_source = Float64[]
    i1 = Float64[]
    i2 = Float64[]
    is = Float64[]
    v_gnd = Float64[]

    for line in data_lines
        if !isempty(strip(line))
            parts = split(line, ',')
            # Filter out empty parts
            valid_parts = filter(p -> !isempty(strip(p)), parts)

            if length(valid_parts) >= 3
                try
                    push!(current_source, parse(Float64, valid_parts[1]))
                    push!(v_gnd, parse(Float64, valid_parts[2]))  # voltage
                    # For i1 and i2, we'll use placeholders or try to parse additional columns
                    if length(valid_parts) >= 4
                        push!(i1, parse(Float64, valid_parts[end]))  # last valid column
                        push!(i2, 0.0)  # placeholder
                    else
                        push!(i1, 0.0)
                        push!(i2, 0.0)
                    end
                    push!(is, 0.0)  # placeholder
                catch e
                    println("Error parsing line: $line, error: $e")
                    continue
                end
            end
        end
    end

    return DataFrame(current_source=current_source, i1=i1, i2=i2, is=is, v_gnd=v_gnd)
end

"""
Extract datetime from filename in format: [... ; YYYY-MM-DD HH_MM_SS].csv
Returns DateTime object or nothing if parsing fails
"""
function extract_datetime_from_filename(filename)
    # Look for pattern like "; 2025-08-06 12_20_59]"
    datetime_match = match(r"; (\d{4}-\d{2}-\d{2}) (\d{2})_(\d{2})_(\d{2})\]", filename)
    if datetime_match !== nothing
        date_part = datetime_match.captures[1]
        hour = datetime_match.captures[2]
        minute = datetime_match.captures[3]
        second = datetime_match.captures[4]

        try
            # Construct full datetime string
            datetime_str = "$(date_part) $(hour):$(minute):$(second)"
            return DateTime(datetime_str, "yyyy-mm-dd HH:MM:SS")
        catch e
            println("Warning: Could not parse datetime from '$filename': $e")
            return nothing
        end
    end
    return nothing
end

@setup_workload begin
    # TODO
    @compile_workload begin
        # TODO
    end
end


end # module
