"""
BonitoInterface.jl - Main Bonito-based GUI interface
"""

using Bonito
using WGLMakie
using Observables

# MeasurementData and PlotGenerator are already included in main module

"""
Start the measurement browser GUI
"""
function start_browser(root_path::String = pwd(); port::Int = 8000)
    app = create_app(root_path)
    
    # Open the browser
    println("Starting browser on port $port...")
    # Use Bonito.Server with the new API
    server = Bonito.Server(app, "127.0.0.1", port)
    println("Browser started! Open http://localhost:$port in your web browser")
    return server
end

function create_app(root_path::String)
    # Scan directory for measurements
    println("Scanning directory: $root_path")
    hierarchy = scan_directory(root_path)
    println("Found $(length(hierarchy.all_measurements)) measurements")

    # Create a new Bonito app
    app = App() do session::Session
        # Observables for reactive state
        selected_chip = Observable{Union{String, Nothing}}(nothing)
        selected_subsite = Observable{Union{String, Nothing}}(nothing)
        selected_device = Observable{Union{String, Nothing}}(nothing)
        selected_measurement = Observable{Union{MeasurementInfo, Nothing}}(nothing)
        current_plot = Observable{Union{Any, Nothing}}(nothing)
        
        # Create the main layout
        return create_main_layout(scan_directory(root_path), selected_chip, selected_subsite, 
                                  selected_device, selected_measurement, current_plot)
    end
    
    return app
end

"""
Create the main application layout
"""
function create_main_layout(hierarchy, selected_chip, selected_subsite, 
                          selected_device, selected_measurement, current_plot)
    
    # Left panel: Device tree
    device_tree = create_device_tree(hierarchy, selected_chip, selected_subsite, selected_device)
    
    # Middle panel: Measurement list
    measurement_list = create_measurement_list(hierarchy, selected_chip, selected_subsite, 
                                             selected_device, selected_measurement)
    
    # Right panel: Plot area
    plot_area = create_plot_area(selected_measurement, current_plot)
    
    # Bottom panel: Info panel
    info_panel = create_info_panel(selected_measurement)
    
    # Main layout
    return DOM.div(
        style="display: grid; grid-template-columns: 250px 300px 1fr; grid-template-rows: 1fr 200px; height: 100vh; gap: 10px; padding: 10px;",
        
        # Device tree (left)
        DOM.div(
            style="grid-column: 1; grid-row: 1 / 3; border: 1px solid #ccc; padding: 10px; overflow-y: auto;",
            DOM.h3("Devices"),
            device_tree
        ),
        
        # Measurement list (middle top)
        DOM.div(
            style="grid-column: 2; grid-row: 1; border: 1px solid #ccc; padding: 10px; overflow-y: auto;",
            DOM.h3("Measurements"),
            measurement_list
        ),
        
        # Plot area (right)
        DOM.div(
            style="grid-column: 3; grid-row: 1; border: 1px solid #ccc; padding: 10px;",
            DOM.h3("Plot"),
            plot_area
        ),
        
        # Info panel (middle and right bottom)
        DOM.div(
            style="grid-column: 2 / 4; grid-row: 2; border: 1px solid #ccc; padding: 10px; overflow-y: auto;",
            DOM.h3("Information"),
            info_panel
        )
    )
end

"""
Create expandable device tree
"""
function create_device_tree(hierarchy, selected_chip, selected_subsite, selected_device)
    tree_elements = []
    
    for (chip_name, chip_data) in hierarchy.chips
        # Chip level
        chip_count = sum(length(device_measurements) for subsite in values(chip_data) for device_measurements in values(subsite))
        chip_element = DOM.div(
            DOM.div(
                Button(
                    "📁 $chip_name ($chip_count measurements)",
                    style=Styles(
                        CSS("background" => "none"),
                        CSS("border" => "none"),
                        CSS("cursor" => "pointer"),
                        CSS("font-weight" => "bold"),
                        CSS("text-align" => "left"),
                    )
                )
            ),
            DOM.div(
                style="margin-left: 1em;",
                [create_subsite_tree(subsite_name, subsite_data, selected_subsite, selected_device) 
                 for (subsite_name, subsite_data) in chip_data]...
            )
        )
        push!(tree_elements, chip_element)
    end
    
    return DOM.div(tree_elements...)
end

"""
Create subsite tree level
"""
function create_subsite_tree(subsite_name, subsite_data, selected_subsite, selected_device)
    subsite_count = sum(length(device_measurements) for device_measurements in values(subsite_data))
    
    device_elements = []
    for (device_name, measurements) in subsite_data
        device_element = DOM.div(
            Button(
                "🔧 $device_name ($(length(measurements)))",
                style=Styles(
                    CSS("background" => "none"),
                    CSS("border" => "none"),
                    CSS("cursor" => "pointer"),
                    CSS("color" => "#0066cc"),
                    CSS("text-align" => "left")
                ),
            )
        )
        push!(device_elements, device_element)
    end

    tree = DOM.div(
        Button(
            "📂 $subsite_name ($subsite_count)",
            style=Styles(
                CSS("background" => "none"),
                CSS("border" => "none"),
                CSS("cursor" => "pointer"),
                CSS("font-weight" => "bold"),
                CSS("color" => "#0066cc"),
                CSS("text-align" => "left")
            )
        ),
        DOM.div(
            style="margin-left: 1em;",
            device_elements...
        )
    )
    
    return DOM.div(
        style="margin-bottom: 3px;",
        tree,
    )
end

"""
Create measurement list for selected device
"""
function create_measurement_list(hierarchy, selected_chip, selected_subsite, 
                                selected_device, selected_measurement)
    
    # Reactive measurement list based on selected device
    measurement_elements = map(selected_device) do device_name
        if device_name === nothing
            return [DOM.p("Select a device to view measurements")]
        end
        
        # Find measurements for this device
        measurements = MeasurementInfo[]
        for (chip_name, chip_data) in hierarchy.chips
            for (subsite_name, subsite_data) in chip_data
                if haskey(subsite_data, device_name)
                    append!(measurements, subsite_data[device_name])
                end
            end
        end
        
        if isempty(measurements)
            return [DOM.p("No measurements found for this device")]
        end
        
        # Create measurement cards
        return [create_measurement_card(measurement, selected_measurement) for measurement in measurements]
    end
    
    return DOM.div(measurement_elements)
end

"""
Create individual measurement card
"""
function create_measurement_card(measurement, selected_measurement)
    # Get measurement summary
    summary = get_measurement_summary(measurement)
    
    # Format timestamp
    time_str = measurement.timestamp !== nothing ? 
               Dates.format(measurement.timestamp, "HH:MM:SS") : "Unknown"
    
    # Create thumbnail (placeholder for now)
    thumbnail_style = "width: 60px; height: 40px; background: #f0f0f0; border: 1px solid #ccc; display: inline-block; margin-right: 10px;"
    
    return DOM.div(
        style="border: 1px solid #ddd; margin: 5px 0; padding: 8px; cursor: pointer; border-radius: 4px;",
        # TODO: Add interactive functionality - currently disabled due to @js macro issues
        # onmouseenter=js"this.style.backgroundColor = '#f5f5f5'",
        # onmouseleave=js"this.style.backgroundColor = 'white'",
        # onclick=@js function ()
        #     $selected_measurement[] = $measurement
        # end,
        
        DOM.div(
            style="display: flex; align-items: center;",
            
            # Thumbnail placeholder
            DOM.div(style=thumbnail_style, "📊"),
            
            # Measurement info
            DOM.div(
                DOM.div(measurement.measurement_type, style="font-weight: bold; font-size: 12px;"),
                DOM.div(time_str, style="font-size: 10px; color: #666;"),
                DOM.div(
                    [DOM.span("$(k): $(v) ", style="font-size: 10px; color: #888;") 
                     for (k, v) in measurement.parameters]..., 
                    style="margin-top: 2px;"
                )
            )
        )
    )
end

"""
Create plot area
"""
function create_plot_area(selected_measurement, current_plot)
    
    # Reactive plot based on selected measurement
    plot_content = map(selected_measurement) do measurement
        if measurement === nothing
            return DOM.div(
                style="display: flex; align-items: center; justify-content: center; height: 400px; color: #999;",
                "Select a measurement to view plot"
            )
        end
        
        # Generate plot
        try
            fig = generate_full_plot(measurement)
            if fig !== nothing
                current_plot[] = fig
                return Bonito.html_to_node(WGLMakie.to_html(current_plot[]))
            else
                return DOM.div("Failed to generate plot")
            end
        catch e
            return DOM.div("Error generating plot: $e")
        end
    end
    
    return DOM.div(plot_content)
end

"""
Create information panel
"""
function create_info_panel(selected_measurement)
    
    info_content = map(selected_measurement) do measurement
        if measurement === nothing
            return [DOM.p("Select a measurement to view details")]
        end
        
        summary = get_measurement_summary(measurement)
        
        info_items = [
            DOM.h4("Measurement Details"),
            DOM.p("File: $(measurement.filename)"),
            DOM.p("Type: $(measurement.measurement_type)"),
        ]
        
        if measurement.timestamp !== nothing
            time_str = Dates.format(measurement.timestamp, "yyyy-mm-dd HH:MM:SS")
            push!(info_items, DOM.p("Time: $time_str"))
        end
        
        # Add device info
        push!(info_items, DOM.h4("Device Information"))
        push!(info_items, DOM.p("Chip: $(measurement.device_info.chip)"))
        push!(info_items, DOM.p("Subsite: $(measurement.device_info.subsite)"))
        push!(info_items, DOM.p("Device: $(measurement.device_info.device)"))
        
        # Add parameters
        if !isempty(measurement.parameters)
            push!(info_items, DOM.h4("Parameters"))
            for (key, value) in measurement.parameters
                push!(info_items, DOM.p("$key: $value"))
            end
        end
        
        # Add data summary
        if haskey(summary, "data_points")
            push!(info_items, DOM.h4("Data Summary"))
            push!(info_items, DOM.p("Data points: $(summary["data_points"])"))
            
            for (key, value) in summary
                if key ∉ ["type", "timestamp", "parameters", "data_points"]
                    if isa(value, Tuple) && length(value) == 2
                        push!(info_items, DOM.p("$key: $(value[1]) to $(value[2])"))
                    else
                        push!(info_items, DOM.p("$key: $value"))
                    end
                end
            end
        end
        
        return info_items
    end
    
    return DOM.div(info_content)
end
