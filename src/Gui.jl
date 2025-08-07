import GLFW
using GLMakie
import GLMakie.Makie as Makie
import CImGui as ig
import CImGui.CSyntax: @c
import ModernGL as gl

function render_main_window(ui_state)
    if ig.Begin("Measurement Browser", C_NULL, ig.ImGuiWindowFlags_MenuBar)
    end
    ig.End()
end

function render_menu_bar(ui_state)
    if ig.BeginMenuBar()
        if ig.BeginMenu("File")
            if ig.MenuItem("Open Folder...")
                # Prompt for folder selection via kdialog
                path = try
                    String(readchomp(`kdialog --getexistingdirectory`))
                catch
                    @error "Failed to open folder selection dialog"
                end
                if !isempty(path)
                    @info "Selected path: $path"
                    # Scan and populate device hierarchy
                    hierarchy = scan_directory(path)
                    ui_state[:devices] = hierarchy.chips
                    ui_state[:all_measurements] = hierarchy.all_measurements
                    ui_state[:root_path] = path
                end
            end
            ig.EndMenu()
        end
        ig.EndMenuBar()
    end
end

function render_device_tree(ui_state)
    # Recursive renderer for arbitrary nested Dict trees
    function render_tree_node(name::String, node, ui_state, path=String[])
        if node isa Dict
            if ig.TreeNode(name)
                for (child_name, child_node) in node
                    render_tree_node(child_name, child_node, ui_state, [path...; name])
                end
                ig.TreePop()
            end
        elseif node isa AbstractVector
            # Leaf node: measurement vector
            full_path = [path...; name]
            selected = get(ui_state, :selected_device, nothing) == full_path
            if ig.Selectable(name, selected)
                ui_state[:selected_device] = full_path
                # store the measurements for right panel
                ui_state[:selected_measurements] = node
            end
        end
    end

    if ig.Begin("Device Hierarchy", C_NULL, ig.ImGuiWindowFlags_MenuBar)
        render_menu_bar(ui_state)
        # Main layout with two columns
        ig.Columns(2, "main_layout")
        # ig.SetColumnWidth(0, 300)

        ig.BeginChild("Device Tree", (0, 0), true)
        # Left panel: Hierarchical device tree
        if haskey(ui_state, :devices)
            for (name, node) in ui_state[:devices]
                render_tree_node(name, node, ui_state)
            end
        else
            ig.Text("No data found")
        end
        ig.EndChild()
        ig.NextColumn()

        # Right panel: measurement selection
        ig.BeginChild("right_panel", (0, 0), true)
        if haskey(ui_state, :selected_measurements)
            measurements = ui_state[:selected_measurements]
            ig.Text("Measurements for " * (haskey(ui_state, :selected_device) ? last(ui_state[:selected_device]) : "" ) * ":")
            for measurement in measurements
                selected = get(ui_state, :selected_measurement, nothing) == measurement
                if ig.Selectable(measurement.filename, selected)
                    ui_state[:selected_measurement] = measurement
                end
            end
        else
            ig.Text("Select a device to view measurements")
        end
        ig.EndChild()
    end
    ig.End()
end


function render_plot_window(ui_state)
    if ig.Begin("Plot Area")
        ig.Text("Plot")
        # TODO: show plot
    end
    ig.End()
end

function render_info_window(ui_state)
    if ig.Begin("Information Panel")
        ig.Text("Information")
        # TODO: show info
    end
    ig.End()
end

function create_window_and_run_loop(root_path::Union{Nothing,String}=nothing; engine=nothing, spawn=1)
    # Setup DearImGui
    ig.set_backend(:GlfwOpenGL3)
    ctx = ig.CreateContext()
    io = ig.GetIO()
    io.ConfigFlags = unsafe_load(io.ConfigFlags) | ig.ImGuiConfigFlags_DockingEnable
    io.ConfigFlags = unsafe_load(io.ConfigFlags) | ig.ImGuiConfigFlags_ViewportsEnable

    # set theme
    ig.StyleColorsDark()

    # ui state dictionary
    ui_state = Dict{Symbol,Any}()
    # Auto-load provided root_path
    if root_path !== nothing && root_path != ""
        hierarchy = scan_directory(root_path)
        ui_state[:devices] = hierarchy.chips
        ui_state[:all_measurements] = hierarchy.all_measurements
        ui_state[:root_path] = root_path
    end

    # main window
    ig.render(ctx; engine, window_size=(1280, 720), window_title="Measurement Browser", spawn) do
        render_device_tree(ui_state)
        render_info_window(ui_state)
        render_plot_window(ui_state)
    end
end

# Entry point
function start_browser(root_path::Union{Nothing,String}=nothing)
    # TODO: use root_path to load data
    create_window_and_run_loop(root_path)
end