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
                path = try
                    String(readchomp(`kdialog --getexistingdirectory`))
                catch
                    @error "Failed to open folder selection dialog"
                end
                if !isempty(path)
                    @info "Selected path: $path"
                    hierarchy = scan_directory(path)
                    ui_state[:hierarchy_root] = hierarchy.root
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
    # Recursive renderer for HierarchyNode tree
    function render_node(node::HierarchyNode, path::Vector{String}=String[])
        full_path = vcat(path, node.name)
        if isempty(children(node))
            label = node.name
            selected = get(ui_state, :selected_path, String[]) == full_path
            if ig.Selectable(label, selected)
                ui_state[:selected_path] = full_path
                ui_state[:selected_measurements] = node.measurements
            end
        else
            open = ig.TreeNode(node.name)
            if open
                for child in children(node)
                    render_node(child, full_path)
                end
                ig.TreePop()
            end
        end
    end

    if ig.Begin("Hierarchy", C_NULL, ig.ImGuiWindowFlags_MenuBar)
        render_menu_bar(ui_state)
        ig.Columns(2, "main_layout")
        ig.BeginChild("Tree", (0, 0), true)
        if haskey(ui_state, :hierarchy_root)
            for child in children(ui_state[:hierarchy_root])
                render_node(child)
            end
        else
            ig.Text("No data loaded")
        end
        ig.EndChild()
        ig.NextColumn()
        ig.BeginChild("Measurements", (0,0), true)
        if haskey(ui_state, :selected_measurements)
            meas_vec = ui_state[:selected_measurements]
            sel_name = join(get(ui_state, :selected_path, [""]), "/")
            ig.Text("Measurements for " * sel_name)
            ig.Separator()
            for m in meas_vec
                selected = get(ui_state, :selected_measurement, nothing) == m
                if ig.Selectable(meas_id(m), selected)
                    ui_state[:selected_measurement] = m
                end
            end
        else
            ig.Text("Select a leaf to view measurements")
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
        ig.Columns(2, "info_cols")
        # ---- Column 1: Device stats ----
        if haskey(ui_state, :selected_measurements)
            meas_vec = ui_state[:selected_measurements]
            sel_name = join(get(ui_state, :selected_path, [""]), "/")
            ig.Text("Device: " * sel_name)
            stats = try
                get_device_stats(meas_vec)
            catch err
                @warn "Failed to compute stats" error=err
                Dict{String,Any}()
            end
            ig.Separator()
            if !isempty(stats)
                ig.Text("Stats")
                ig.BulletText("Total: $(stats["total_measurements"])\n")
                ig.BulletText("Types: $(join(stats["measurement_types"], ", "))")
                if haskey(stats, "first_measurement")
                    ig.BulletText("First: $(stats["first_measurement"]) ")
                    ig.BulletText("Last:  $(stats["last_measurement"]) ")
                    ig.BulletText("Duration: $(stats["duration"]) ")
                end
                if haskey(stats, "parameter_ranges") && !isempty(stats["parameter_ranges"])
                    ig.Separator()
                    ig.Text("Parameter ranges")
                    for (p,(mn,mx)) in stats["parameter_ranges"]
                        ig.BulletText("$(p): $(mn) – $(mx)")
                    end
                end
            else
                ig.Text("No stats available")
            end
        else
            ig.Text("Select a device to see details")
        end

        ig.NextColumn()
        # ---- Column 2: Measurement details ----
        if haskey(ui_state, :selected_measurement)
            m = ui_state[:selected_measurement]
            ig.Text("Selected Measurement")
            ig.Separator()
            ig.BulletText("Title: $(m.clean_title)")
            ig.BulletText("Type: $(m.measurement_type)")
            ig.BulletText("Timestamp: $(m.timestamp)")
            ig.BulletText("Filename: $(m.filename)")
            ig.BulletText("Path: $(m.filepath)")
            di = m.device_info
            ig.Separator()
            ig.Text("Device Info")
            ig.BulletText("Chip: $(di.chip)")
            ig.BulletText("Subsite: $(di.subsite)")
            ig.BulletText("Device: $(di.device)")
            ig.BulletText("Full Path: $(di.full_path)")
            if !isempty(m.parameters)
                ig.Separator()
                ig.Text("Parameters")
                for (k,v) in m.parameters
                    ig.BulletText("$(k) = $(v)")
                end
            end
        else
            ig.Text("Select a measurement to view details")
        end
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
        ui_state[:hierarchy_root] = hierarchy.root
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