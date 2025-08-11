using CSV, DataFrames, Statistics, SmoothData, Dates

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
Simple breakdown analysis for I-V data
"""
function analyze_breakdown(df, threshold_current=1e-6)
    if nrow(df) == 0
        return Dict()
    end

    abs_current = abs.(df.current1)
    breakdown_idx = findfirst(x -> x > threshold_current, abs_current)
    breakdown_voltage = breakdown_idx !== nothing ? df.voltage[breakdown_idx] : NaN
    leakage_current = breakdown_idx !== nothing ? mean(abs_current[1:max(1, breakdown_idx - 5)]) : mean(abs_current)

    return Dict(
        "breakdown_voltage" => breakdown_voltage,
        "leakage_current" => leakage_current,
        "max_current" => maximum(abs_current),
        "voltage_range" => (minimum(df.voltage), maximum(df.voltage))
    )
end


"""
Perform PUND analysis on the DataFrame

    # 1. identify triangular voltage pulse train
    # 2. get current in P_n and U_n pulses
    # 3. subtract I_Pn - I_Un = I_FEn
    # 4. integrate I_FEn(t) dt = Q_FEn
    # 5. return analysis dataframe with Q_FE in each row

from this, Q_FE(V) or Q_FE(t) can be very easily extracted
"""
function analyze_pund(df::DataFrame)
    @assert all(["time", "voltage", "current"] .∈ Ref(names(df))) "columns :time, :voltage, :current must exist"
    t, V, I = df[!, :time], df[!, :voltage], df[!, :current]
    N = length(t)

    # offset current data to zero
    I .-= mean(skipmissing(filter(!isnan, I[1:75])))

    # ---- helper: contiguous true–runs --------------------------------------------------
    function true_runs(mask::BitVector)
        runs = UnitRange{Int}[]
        start = nothing
        for i ∈ eachindex(mask)
            if mask[i]
                start === nothing && (start = i)
            elseif start !== nothing
                push!(runs, start:i-1)
                start = nothing
            end
        end
        start !== nothing && push!(runs, start:lastindex(mask))
        return runs
    end

    # ---- pulse detection ---------------------------------------------------------------
    # Use smoothed derivative detection to capture full triangular pulses
    dV = smoothdata([0.0; diff(V)], :movmedian, 9)
    baseline_dV = std(dV[1:min(75, length(dV) ÷ 10)])
    dV_threshold = baseline_dV * 5
    # Find regions with significant voltage changes
    pulse_mask = abs.(dV) .> dV_threshold

    # Expand pulse regions to capture full triangular waves
    expanded_mask = copy(pulse_mask)
    safe_win = 5  # Larger expansion window
    for i in (safe_win+1):(length(pulse_mask)-safe_win)
        if any(pulse_mask[(i-safe_win):(i+safe_win)])
            expanded_mask[i] = true
        end
    end
    all_pulses = true_runs(expanded_mask)

    # Filter out short pulses and pulses with small voltage amplitudes
    baseline_V = mean(abs.(V[1:min(100, length(V))]))
    min_pulse_length = 100  # minimum points for a valid pulse
    min_voltage_amplitude = baseline_V * 5  # minimum voltage amplitude

    pulses = UnitRange{Int}[]
    for pulse in all_pulses
        if length(pulse) >= min_pulse_length
            pulse_V_range = maximum(abs.(V[pulse]))
            if pulse_V_range >= min_voltage_amplitude
                push!(pulses, pulse)
            end
        end
    end

    @assert !isempty(pulses) "no valid pulses found; adjust derivative threshold or filtering parameters"

    # ---- polarity alignment --------------------------------------------------------
    mismatches = 0
    total = 0
    for pulse in pulses
        # take only the first half of the pulse in case it is dominated by I=dV/dt
        # (and thus mean(I) ~ 0)
        V_avg, I_avg = mean(V[pulse[1:end÷2]]), mean(I[pulse[1:end÷2]])
        if abs(V_avg) > 0 && abs(I_avg) > 0
            total += 1
            mismatches += sign(V_avg) != sign(I_avg)
        end
    end

    if total > 0 && mismatches == total
        I = -I
    elseif mismatches > 0
        error("Inconsistent polarity: $(mismatches)/$(total) pulses misaligned")
    end

    # ---- consistency check and grouping into quintuples --------------------------------
    groups = [(pulses[i], pulses[i+1], pulses[i+2], pulses[i+3], pulses[i+4]) for i in 1:5:length(pulses)-4]

    for g in groups
        poling, P, U, Np, D = Tuple(g)
        sP, sPol = sign(sum(V[P])), sign(sum(V[poling]))
        @assert sPol == -sP &&
                sign(sum(V[U])) == sP &&
                sign(sum(V[Np])) == -sP &&
                sign(sum(V[D])) == -sP "unexpected pulse ordering"
    end

    # ---- allocate result columns -------------------------------------------------------
    polarity = zeros(Int8, N)
    pulse_idx = zeros(Int, N)
    I_FE = zeros(eltype(I), N)
    Q_FE = fill!(similar(I), NaN)

    # ---- sample-wise subtraction helper -----------------------------------------------
    subtract_aligned(A, B) =
        length(A) == length(B) ?
        A .- B :
        A .- @view(B[round.(Int, LinRange(1, length(B), length(A)))])

    # ---- process every PUND group ------------------------------------------------------
    for (group_idx, (poling, P, U, Np, D)) in enumerate(groups)
        # polarity flags
        polarity[P] .= 1
        polarity[U] .= 1
        polarity[Np] .= -1
        polarity[D] .= -1
        pulse_idx[poling] .= group_idx * 5 - 4
        pulse_idx[P] .= group_idx * 5 - 3
        pulse_idx[U] .= group_idx * 5 - 2
        pulse_idx[Np] .= group_idx * 5 - 1
        pulse_idx[D] .= group_idx * 5

        # positive switching
        I_FE_P = subtract_aligned(I[P], I[U])
        I_FE[P] = I_FE_P

        # negative switching
        I_FE_N = subtract_aligned(I[Np], I[D])
        I_FE[Np] = I_FE_N
    end

    # ---- cumulative integral: trapezoidal rule ----------------------------------------
    dt = [zero(t[1]); diff(t)]
    dQ = I_FE .* dt
    q = 0.0
    for i ∈ eachindex(I_FE)
        # Only integrate during P and N switching pulses
        if (pulse_idx[i] % 5 == 2 || pulse_idx[i] % 5 == 4)
            q += dQ[i]
            Q_FE[i] = q
        else
            Q_FE[i] = NaN  # Set NaN outside P and N pulses
        end
    end

    # ---- assemble and return -----------------------------------------------------------
    df[!, :current] .= I # fix polarity
    return hcat(df, DataFrame(polarity=polarity, pulse_idx=pulse_idx, I_FE=I_FE, Q_FE=Q_FE))
end

function analyze_files(workdir=".")
    all_files = readdir(workdir)
    csv_files = filter(f -> endswith(f, ".csv"), all_files)
    categories = Dict{String,Vector{String}}()
    file_info = Dict{String,Dict{String,Any}}()
    patterns = [
        ("I-V Sweep", r"I_V Sweep"),
        ("FE PUND", r"FE PUND"),
        ("TLM 4-Point", r"TLM_4P"),
        ("Breakdown", r"Break.*oxide"),
        ("Wakeup", r"Wakeup"),
        ("Chuck Test", r"chuck")
    ]
    for file in csv_files
        info = extract_file_info(file, workdir)
        category = "Other"
        for (cat_name, pattern) in patterns
            if occursin(pattern, file)
                category = cat_name
                break
            end
        end
        if !haskey(categories, category)
            categories[category] = String[]
        end
        push!(categories[category], file)
        file_info[file] = merge(info, Dict("category" => category))
    end
    return (categories, file_info)
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

"""
Sort a list of filenames by their embedded datetime
Files with unparseable dates are placed at the end
"""
function sort_files_by_datetime(files)
    # Create list of (filename, datetime) tuples
    file_datetime_pairs = []
    files_without_datetime = String[]
    
    for file in files
        dt = extract_datetime_from_filename(file)
        if dt !== nothing
            push!(file_datetime_pairs, (file, dt))
        else
            push!(files_without_datetime, file)
        end
    end
    
    # Sort by datetime
    sorted_pairs = sort(file_datetime_pairs, by = x -> x[2])
    
    # Return sorted filenames, with unparseable dates at the end
    sorted_files = [pair[1] for pair in sorted_pairs]
    append!(sorted_files, files_without_datetime)
    
    return sorted_files
end