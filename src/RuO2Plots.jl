using GLMakie, DataFrames, Statistics
export figure_for_file

"""
Set up Makie backend
"""
function setup_makie()
    GLMakie.activate!()
end

"""
Open the figure in a new window rather than replacing the current one
"""
function display_new_window(fig)
    DataInspector(fig)
    display(GLMakie.Screen(), fig)
end

"""
Plot I-V sweep data for a single DataFrame
"""
function plot_iv_sweep_single(df, title_str="I-V Sweep")
    if nrow(df) == 0
        return nothing
    end

    fig = Figure(size=(800, 600))
    ax = Axis(fig[1, 1], xlabel="Voltage (V)", ylabel="Current (A)", title=title_str)

    lines!(ax, df.voltage, df.current1, color=:blue, linewidth=2, label="Current1")
    if hasproperty(df, :current2) && any(df.current1 .!= df.current2)
        lines!(ax, df.voltage, df.current2, color=:red, linewidth=2, label="Current2")
        axislegend(ax, position=:rt)
    end

    return fig
end

"""
Plot I-V sweep data for a vector of files, grouped by device.
"""
function plot_iv_sweep(files::Vector{Tuple{String,DataFrame}})
    device_data = Dict{String,Vector{Tuple{String,DataFrame}}}()

    # Group files by device
    for (file, df) in files
        m = match(r"RuO2test_A2_([^_\[]+)_([^_\[\(]+)", file)
        device = m !== nothing ? "$(m.captures[1])_$(m.captures[2])" : "Unknown Device"
        if !haskey(device_data, device)
            device_data[device] = Vector{Tuple{String,DataFrame}}()
        end
        push!(device_data[device], (file, df))
    end

    plot_iv_sweep_by_device(device_data)
end

"""
Plot I-V sweep data grouped by device in separate windows
"""
function plot_iv_sweep_by_device(device_data::Dict{String,Vector{Tuple{String,DataFrame}}})
    for (device, files) in sort(collect(device_data))
        fig = Figure(size=(1000, 600))

        ax = Axis(fig[1, 1], xlabel="Voltage (V)", ylabel="Current (A)",
            title="I-V Sweep for $(device)")

        # Create gradient of colors using the viridis colormap
        nfiles = length(files)
        color_gradient = cgrad(:matter, nfiles, categorical=true)

        # Observable toggle for absolute/raw current
        abs_mode = Observable(true)

        # Plot each file's data
        for (j, (file_label, df)) in enumerate(files)
            label = clean_title(file_label)
            lines!(ax, df.voltage, @lift(if $abs_mode
                    abs.(df.current1)
                else
                    df.current1
                end),
                color=color_gradient[j], label=label)
        end

        axislegend(ax, position=:rt)

        # Add toggle button for absolute/raw current
        gl = GridLayout(fig[2, 1], tellwidth=false)
        Label(gl[1, 1], "Absolute Value")
        toggle = Toggle(gl[1, 2], active=abs_mode[])
        on(toggle.active) do val
            abs_mode[] = val
        end

        # add toggle button for log scale
        Label(gl[2, 1], "Log Scale")
        toggle_log = Toggle(gl[2, 2], active=false)
        on(toggle_log.active) do val
            abs_mode[] = val ? true : abs_mode[]
            ax.yscale = val ? log10 : identity
        end

        display_new_window(fig)
    end
end

"""
Plot FE PUND data with comprehensive visualization
"""
function plot_fe_pund(df, title_str="FE PUND")
    if nrow(df) == 0
        return nothing
    end

    df = analyze_pund(df)

    time_us = df.time * 1e6
    fig = Figure(size=(1200, 800))

    # create axes
    ax1 = Axis(fig[1, 1:2], xlabel="Time (μs)", ylabel="Current (μA)", yticklabelcolor=:blue, title="$title_str - Combined")
    ax1twin = Axis(fig[1, 1:2], yaxisposition=:right, ylabel="Voltage (V)", yticklabelcolor=:red)
    ax2 = Axis(fig[2, 1], xlabel="Voltage (V)", ylabel="Current (μA)", title="$title_str - I-V Characteristic")
    ax3 = Axis(fig[2, 2], xlabel="Voltage (V)", ylabel="Charge (pC)", title="$title_str - Ferroelectric Switching Charge")
    linkaxes!(ax1, ax1twin)

    # Combined I, V plot
    l1 = lines!(ax1, time_us, df.current * 1e6, color=:blue, linewidth=2)
    l2 = lines!(ax1twin, time_us, df.voltage, color=:red, linewidth=2, linestyle=:dash)
    l3 = lines!(ax1, time_us, df.I_FE * 1e6, color=:purple, linewidth=2)

    # Current vs Voltage (hysteresis loop)
    lines!(ax2, df.voltage, df.current * 1e6, color=:green, linewidth=2)
    lines!(ax2, df.voltage, df.I_FE * 1e6, color=:purple, linewidth=2)

    # Remant charge - align P and N pulses
    Q_FE = df.Q_FE .- mean(filter(!isnan, df.Q_FE))

    # Plot each PUND repetition separately for legend
    for rep in 1:maximum(df.pulse_idx)÷5
        pulse_range = (rep-1)*5+1:rep*5
        mask = [p in pulse_range for p in df.pulse_idx]
        if any(mask)
            lines!(ax3, df.voltage[mask], Q_FE[mask] * 1e12, linewidth=2, color=:purple, label="$rep")
        end
    end

    # legends
    Legend(fig[1, 1], [l1, l2, l3], ["Current", "Voltage", "FE Current"], tellwidth=false, tellheight=false, halign=:left, valign=:top)
    axislegend(ax3)

    return fig
end

"""
    figure_for_file(path::AbstractString) -> Union{Figure,Nothing}

Given a filepath to a measurement CSV, detect its measurement type
from the filename alone (no MeasurementInfo dependency), load the data
with the appropriate reader, and return a Makie Figure. Returns `nothing`
if unsupported or loading/plotting fails.
"""
function figure_for_file(path::AbstractString)
    isfile(path) || return nothing
    fname = basename(path)
    dir = dirname(path)
    lower = lowercase(fname)

    # Helper to derive a title (strip .csv)
    title = strip(replace(fname, r"\.csv$" => ""))

    df = nothing
    fig = nothing
    try
        if occursin("fe pund", lower) || occursin("fepund", lower)
            df = read_fe_pund(fname, dir)
            fig = plot_fe_pund(df, title)
        elseif occursin("i_v sweep", lower) || occursin("iv sweep", lower)
            df = read_iv_sweep(fname, dir)
            fig = plot_iv_sweep_single(df, title)
        elseif occursin("tlm_4p", lower) || occursin("tlm", lower)
            df = read_tlm_4p(fname, dir)
            fig = plot_tlm_4p(df, title)
        elseif occursin("break", lower) || occursin("breakdown", lower)
            # Treat as breakdown I-V for now
            df = read_iv_sweep(fname, dir)
            fig = plot_iv_sweep_single(df, title * " (Breakdown)")
        else
            # Fallback attempt: try I-V sweep reader
            try
                df = read_iv_sweep(fname, dir)
                fig = plot_iv_sweep_single(df, title)
            catch
                return nothing
            end
        end
    catch err
        @warn "figure_for_file failed" path error = err
        return nothing
    end

    return fig
end

"""
Plot TLM 4-point data with detailed analysis
"""
function plot_tlm_4p(df, title_str="TLM 4-Point")
    if nrow(df) == 0
        return nothing
    end

    current_source_ua = df.current_source * 1e6
    i1_ua = df.i1 * 1e6
    i2_ua = df.i2 * 1e6
    is_ua = df.is * 1e6

    fig = Figure(size=(1200, 1000))

    # Current response with scatter points
    ax1 = Axis(fig[1, 1], xlabel="Source Current (μA)", ylabel="Current (μA)",
        title="$title_str - Current Response")
    lines!(ax1, current_source_ua, i1_ua, color=:blue, linewidth=2, label="I1")
    scatter!(ax1, current_source_ua, i1_ua, color=:blue, markersize=4)
    lines!(ax1, current_source_ua, i2_ua, color=:red, linewidth=2, label="I2")
    scatter!(ax1, current_source_ua, i2_ua, color=:red, markersize=4)
    lines!(ax1, current_source_ua, is_ua, color=:green, linewidth=2, label="Is")
    scatter!(ax1, current_source_ua, is_ua, color=:green, markersize=4)
    axislegend(ax1, position=:rt)

    # Voltage response
    ax2 = Axis(fig[1, 2], xlabel="Source Current (μA)", ylabel="Voltage (V)",
        title="$title_str - Voltage Response")
    lines!(ax2, current_source_ua, df.v_gnd, color=:purple, linewidth=2, label="V_GND")
    scatter!(ax2, current_source_ua, df.v_gnd, color=:purple, markersize=4)
    axislegend(ax2, position=:rt)

    # Resistance calculation
    resistance = df.v_gnd ./ df.current_source
    finite_mask = isfinite.(resistance)

    ax3 = Axis(fig[2, 1], xlabel="Source Current (μA)", ylabel="Resistance (Ω)",
        title="$title_str - Resistance vs Current")
    if any(finite_mask)
        lines!(ax3, current_source_ua[finite_mask], resistance[finite_mask],
            color=:orange, linewidth=2, label="R = V/I")
        scatter!(ax3, current_source_ua[finite_mask], resistance[finite_mask],
            color=:orange, markersize=4)
    end
    axislegend(ax3, position=:rt)

    # Current distribution comparison
    ax4 = Axis(fig[2, 2], xlabel="Source Current (μA)", ylabel="Current (μA)",
        title="$title_str - Current Distribution")
    lines!(ax4, current_source_ua, i1_ua, color=:blue, linewidth=2, label="I1")
    lines!(ax4, current_source_ua, i2_ua, color=:red, linewidth=2, label="I2")
    lines!(ax4, current_source_ua, is_ua, color=:green, linewidth=2, label="Is")
    # Add reference line for perfect current transfer
    lines!(ax4, current_source_ua, current_source_ua, color=:black,
        linewidth=1, linestyle=:dash, label="Reference")
    axislegend(ax4, position=:rt)

    return fig
end
