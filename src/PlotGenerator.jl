"""
PlotGenerator.jl - Generate plots and thumbnails for measurements
"""

using WGLMakie
using DataFrames
using Statistics
using CSV

function clean_title(filename::String, workdir::String=".")
    # Simple title cleaning - remove extension and path
    base_name = basename(filename)
    return replace(splitext(base_name)[1], "_" => " ")
end

function plot_iv_sweep_single(df::DataFrame, title::String)
    fig = Figure(resolution=(800, 600))
    ax = Axis(fig[1, 1], 
              xlabel="Voltage (V)", 
              ylabel="Current (A)",
              title=title)
    
    if "voltage" in names(df) && "current1" in names(df)
        lines!(ax, df.voltage, df.current1, color=:blue, linewidth=2, label="Current1")
        
        if "current2" in names(df) && any(df.current1 .!= df.current2)
            lines!(ax, df.voltage, df.current2, color=:red, linewidth=2, label="Current2")
            axislegend(ax)
        end
    else
        @warn "Expected columns 'voltage' and 'current1' not found in DataFrame"
    end
    
    return fig
end

function plot_fe_pund(df::DataFrame, title::String)
    if nrow(df) == 0
        @warn "Empty DataFrame provided to plot_fe_pund"
        return nothing
    end
    
    fig = Figure(resolution=(1200, 800))
    
    # Check if required columns exist
    required_cols = ["time", "current", "voltage"]
    if !all(col in names(df) for col in required_cols)
        @warn "Missing required columns for PUND plot: $required_cols"
        return nothing
    end
    
    ax1 = Axis(fig[1, 1], 
               xlabel="Time (s)", 
               ylabel="Current (A)",
               title="$title - Time Series")
    
    lines!(ax1, df.time, df.current, color=:blue, linewidth=2, label="Current")
    
    ax2 = Axis(fig[1, 2],
               xlabel="Voltage (V)",
               ylabel="Current (A)", 
               title="$title - I-V Loop")
    
    lines!(ax2, df.voltage, df.current, color=:green, linewidth=2)
    
    return fig
end

function plot_tlm_4p(df::DataFrame, title::String)
    if nrow(df) == 0
        @warn "Empty DataFrame provided to plot_tlm_4p"
        return nothing
    end
    
    fig = Figure(resolution=(800, 600))
    ax = Axis(fig[1, 1],
              xlabel="Source Current (A)",
              ylabel="Voltage (V)",
              title="$title - TLM Response")
    
    # Check for expected columns
    if "current_source" in names(df) && "v_gnd" in names(df)
        lines!(ax, df.current_source, df.v_gnd, color=:purple, linewidth=2)
        scatter!(ax, df.current_source, df.v_gnd, color=:purple, markersize=4)
    else
        @warn "Expected columns for TLM plot not found"
    end
    
    return fig
end

"""
Generate thumbnail plot for a measurement
"""
function generate_thumbnail(measurement_info, size=(300, 200))
    try
        # Determine plot type based on measurement type
        if measurement_info.measurement_type == "I-V Sweep"
            # For thumbnails, create a simple representation
            fig = Figure(resolution=size)
            ax = Axis(fig[1, 1], xlabel="V", ylabel="I")
            
            # Generate example I-V curve for thumbnail
            v = -2:0.1:2
            i = 1e-12 * exp.(abs.(v)) .* sign.(v)
            lines!(ax, v, i, color=:blue, linewidth=1)
            
            return fig
            
        elseif measurement_info.measurement_type == "FE PUND"
            fig = Figure(resolution=size)
            ax = Axis(fig[1, 1], xlabel="t", ylabel="I")
            
            # Generate example PUND waveform for thumbnail
            t = 0:0.001:0.1
            i = sin.(2π * 50 * t) .* exp.(-t * 10)
            lines!(ax, t, i, color=:green, linewidth=1)
            
            return fig
            
        else
            # Generic thumbnail
            fig = Figure(resolution=size)
            ax = Axis(fig[1, 1])
            text!(ax, 0.5, 0.5, text=measurement_info.measurement_type, 
                  align=(:center, :center))
            return fig
        end
        
    catch e
        @warn "Could not generate thumbnail: $e"
        return nothing
    end
end
