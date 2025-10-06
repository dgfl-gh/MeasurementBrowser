module Analysis

using DataFrames
using Dates
using Statistics, SmoothData

export analyze_breakdown, analyze_pund, extract_tlm_geometry_from_params, analyze_tlm_combined

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
function analyze_pund(df::DataFrame; DEBUG::Bool=false)
    @assert all(["time", "voltage", "current"] .∈ Ref(names(df))) "columns :time, :voltage, :current must exist"
    t, V, I = df[!, :time], df[!, :voltage], df[!, :current]
    N = length(t)

    # offset current data to zero
    n0 = min(10, N)
    baseline_I = mean(skipmissing(filter(!isnan, I[1:n0])))
    if DEBUG
        @info "analyze_pund: baseline current offset" n0 = n0 baseline = baseline_I
    end
    I .-= baseline_I

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
    baseline_dV = std(dV[1:min(10, length(dV) ÷ 10)])
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
    baseline_V = mean(abs.(V[1:min(9, length(V))]))
    min_pulse_length = 20  # minimum points for a valid pulse
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

"""
Validate TLM measurement dataframe for required columns and data quality

Returns (is_valid, issues) where issues is a vector of warning strings
"""
function validate_tlm_dataframe(df::DataFrame, filepath::String="")
    issues = String[]

    # Check required columns
    required_cols = ["current_source", "v_gnd"]
    for col in required_cols
        if !(col in names(df))
            push!(issues, "Missing required column: $col")
        end
    end

    if !isempty(issues)
        return (false, issues)
    end

    # Check for empty data
    if nrow(df) == 0
        push!(issues, "Empty dataframe")
        return (false, issues)
    end

    # Check for all-zero currents (would cause division by zero)
    if all(df.current_source .== 0)
        push!(issues, "All source currents are zero - cannot calculate resistance")
    end

    # Check for excessive NaN/missing values
    nan_fraction = sum(ismissing.(df.current_source) .| isnan.(df.current_source)) / nrow(df)
    if nan_fraction > 0.5
        push!(issues, "More than 50% of current data is missing or NaN")
    end

    voltage_nan_fraction = sum(ismissing.(df.v_gnd) .| isnan.(df.v_gnd)) / nrow(df)
    if voltage_nan_fraction > 0.5
        push!(issues, "More than 50% of voltage data is missing or NaN")
    end

    return (isempty(issues), issues)
end

"""
Calculate sheet resistance from TLM analysis data

Given analyzed TLM data with length and resistance information,
fits a linear relationship R = R_contact + R_sheet * L/W
and returns (sheet_resistance_ohm_per_square, contact_resistance_ohm, r_squared)
"""
function calculate_sheet_resistance(analysis_df::DataFrame)
    if nrow(analysis_df) == 0
        @warn "Empty analysis dataframe for sheet resistance calculation"
        return (NaN, NaN, NaN)
    end

    # Group by length and width to get average resistance per geometry
    geometry_groups = combine(groupby(analysis_df, [:length_um, :width_um]),
        :resistance_ohm => (x -> mean(filter(isfinite, x))) => :avg_resistance_ohm)

    # Filter out invalid data
    valid_mask = isfinite.(geometry_groups.avg_resistance_ohm) .&
                 isfinite.(geometry_groups.length_um) .&
                 isfinite.(geometry_groups.width_um) .&
                 (geometry_groups.width_um .> 0)

    valid_data = geometry_groups[valid_mask, :]

    if nrow(valid_data) < 2
        @warn "Need at least 2 valid geometry points for sheet resistance calculation"
        return (NaN, NaN, NaN)
    end

    # Linear fit: R = R_contact + R_sheet * L/W
    x = valid_data.length_um ./ valid_data.width_um  # L/W ratio
    y = valid_data.avg_resistance_ohm

    n = length(x)
    sum_x = sum(x)
    sum_y = sum(y)
    sum_xy = sum(x .* y)
    sum_x2 = sum(x .^ 2)

    # Linear regression coefficients
    denominator = n * sum_x2 - sum_x^2
    if abs(denominator) < 1e-12
        @warn "Cannot fit sheet resistance - insufficient variation in L/W ratios"
        return (NaN, NaN, NaN)
    end

    sheet_resistance = (n * sum_xy - sum_x * sum_y) / denominator  # slope
    contact_resistance = (sum_y - sheet_resistance * sum_x) / n     # intercept

    # Calculate R-squared
    y_pred = contact_resistance .+ sheet_resistance .* x
    ss_res = sum((y .- y_pred) .^ 2)
    ss_tot = sum((y .- mean(y)) .^ 2)
    r_squared = 1 - ss_res / ss_tot

    return (sheet_resistance, contact_resistance, r_squared)
end

"""
Extract geometry information from device parameters

Returns (length_um, width_um) or (NaN, NaN) if not found
Expects device_params to contain :length_um and :width_um keys
"""
function extract_tlm_geometry_from_params(device_params::Dict{Symbol,Any}, filepath::String="")
    length_um = get(device_params, :length_um, NaN)
    width_um = get(device_params, :width_um, NaN)

    # Try alternative key names
    if isnan(length_um)
        length_um = get(device_params, :length, NaN)
    end
    if isnan(width_um)
        width_um = get(device_params, :width, NaN)
    end

    # If still not found, try fallback filename parsing
    if isnan(length_um) || isnan(width_um)
        @info "Geometry not found in device parameters, trying filename parsing for: $filepath"

        # Remove path and extension
        basename_file = basename(filepath)
        name_part = replace(basename_file, r"\.(csv|txt)$" => "")

        # Pattern to match TLML<length>W<width>
        pattern = r"TLML(\d+)W(\d+)"
        m = match(pattern, name_part)

        if m !== nothing
            length_um = parse(Float64, m.captures[1])
            width_um = parse(Float64, m.captures[2])
            @info "Extracted geometry from filename: L=$(length_um)μm, W=$(width_um)μm"
        else
            @warn "Could not extract geometry from device parameters or filename: $filepath" available_keys = keys(device_params)
            return (NaN, NaN)
        end
    end

    return (Float64(length_um), Float64(width_um))
end

"""
Analyze multiple TLM measurements for combined plotting

Takes a vector of (filepath, dataframe, device_params) tuples and returns a combined analysis DataFrame
suitable for plotting width-normalized resistance vs length.

device_params should contain :length_um and :width_um keys with geometry information.

Returns DataFrame with columns:
- filepath: original file path
- length_um: extracted length in micrometers
- width_um: extracted width in micrometers
- resistance_ohm: calculated resistance (V/I at each current point)
- resistance_normalized: resistance * width (Ω·μm)
- current_source: source current values
- voltage: measured voltage values
"""
function analyze_tlm_combined(files_data_params::Vector{Tuple{String,DataFrame,Dict{Symbol,Any}}}; Vmin=0.0002, Imin=1e-15)
    if isempty(files_data_params)
        @warn "No TLM data provided for combined analysis"
        return DataFrame()
    end

    combined_data = DataFrame()
    processed_files = 0

    for (filepath, df, device_params) in files_data_params
        # Validate the dataframe
        is_valid, issues = validate_tlm_dataframe(df, filepath)
        if !is_valid
            @warn "Skipping invalid TLM file: $filepath" issues = issues
            continue
        end

        if !isempty(issues)
            @warn "TLM data quality issues in $filepath" issues = issues
        end

        # Extract geometry from device parameters
        length_um, width_um = extract_tlm_geometry_from_params(device_params, filepath)

        if isnan(length_um) || isnan(width_um) || length_um <= 0 || width_um <= 0
            @warn "Skipping file with invalid geometry: $filepath (L=$length_um, W=$width_um)"
            continue
        end

        # Calculate resistance from V/I, handling division by zero
        resistance_ohm = similar(df.current_source, Float64)
        for i in eachindex(df.current_source)
            if abs(df.current_source[i]) < Imin  # Avoid division by very small numbers
                resistance_ohm[i] = NaN
            elseif abs(df.v_gnd[i]) < Vmin # avoid inaccurate values
                resistance_ohm[i] = NaN
            else
                resistance_ohm[i] = df.v_gnd[i] / df.current_source[i]
            end
        end

        # Width-normalize the resistance
        resistance_normalized = resistance_ohm .* width_um

        # Create a dataframe for this file
        file_data = DataFrame(
            filepath=fill(filepath, nrow(df)),
            length_um=fill(length_um, nrow(df)),
            width_um=fill(width_um, nrow(df)),
            resistance_ohm=resistance_ohm,
            resistance_normalized=resistance_normalized,
            current_source=df.current_source,
            voltage=df.v_gnd
        )

        # Add device name for plotting
        device_name = "L$(Int(length_um))W$(Int(width_um))"
        file_data.device_name = fill(device_name, nrow(df))

        # Append to combined data
        combined_data = vcat(combined_data, file_data)
        processed_files += 1
    end

    if nrow(combined_data) == 0
        @warn "No valid TLM data after processing all files" attempted_files = length(files_data_params)
    else
        @info "TLM combined analysis completed" n_files = processed_files n_total_files = length(files_data_params) n_points = nrow(combined_data)

        # Calculate and report sheet resistance if we have enough data
        sheet_res, contact_res, r_sq = calculate_sheet_resistance(combined_data)
        if isfinite(sheet_res)
            @info "Sheet resistance analysis" sheet_resistance_ohm_per_sq = sheet_res contact_resistance_ohm = contact_res r_squared = r_sq
        end
    end

    return combined_data
end

end # module
