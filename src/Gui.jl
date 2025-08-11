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
    # CTRL-F filter
    filter_ptr = get!(ui_state, :_imgui_text_filter) do
        ig.ImGuiTextFilter_ImGuiTextFilter(C_NULL)
    end

    # Test if node matches filter directly
    node_matches(node::HierarchyNode) = ig.ImGuiTextFilter_PassFilter(filter_ptr, node.name, C_NULL)

    # Test if node or any descendant matches
    function subtree_matches(node::HierarchyNode)
        if node_matches(node)
            return true
        end
        for c in children(node)
            if subtree_matches(c)
                return true
            end
        end
        return false
    end

    function render_node(node::HierarchyNode, path::Vector{String}=String[], ancestor_direct::Bool=false)
        show_branch = ancestor_direct || subtree_matches(node)
        show_branch || return
        full_path = vcat(path, node.name)
        direct_match = ancestor_direct || node_matches(node)
        ig.TableNextRow(); ig.TableNextColumn()
        unique_id = join(full_path, "/")
        ig.PushID(unique_id)
        is_leaf = isempty(children(node))
        selected = get(ui_state, :selected_path, String[]) == full_path
        flags = ig.ImGuiTreeNodeFlags_OpenOnArrow | ig.ImGuiTreeNodeFlags_OpenOnDoubleClick | ig.ImGuiTreeNodeFlags_NavLeftJumpsToParent | ig.ImGuiTreeNodeFlags_SpanFullWidth | ig.ImGuiTreeNodeFlags_DrawLinesToNodes
        if is_leaf
            flags |= ig.ImGuiTreeNodeFlags_Leaf | ig.ImGuiTreeNodeFlags_Bullet | ig.ImGuiTreeNodeFlags_NoTreePushOnOpen
        end
        if selected
            flags |= ig.ImGuiTreeNodeFlags_Selected
        end
        if ig.ImGuiTextFilter_IsActive(filter_ptr) && direct_match && !is_leaf
            flags |= ig.ImGuiTreeNodeFlags_DefaultOpen
        end
        opened = ig.TreeNodeEx(is_leaf ? "" : node.name, flags, node.name)
        if ig.IsItemClicked() || ig.IsItemFocused()
            ui_state[:selected_path] = full_path
            if is_leaf
                ui_state[:selected_measurements] = node.measurements
            else
                if haskey(ui_state, :selected_measurements)
                    delete!(ui_state, :selected_measurements)
                end
            end
        end
        if opened && !is_leaf
            for c in children(node)
                render_node(c, full_path, direct_match)
            end
            ig.TreePop()
        end
        ig.PopID()
    end

    if ig.Begin("Hierarchy", C_NULL, ig.ImGuiWindowFlags_MenuBar)
        ig.SetNextItemWidth(-1)
        ig.SetNextItemShortcut(ig.ImGuiMod_Ctrl | ig.ImGuiKey_F, ig.ImGuiInputFlags_Tooltip)
        ig.ImGuiTextFilter_Draw(filter_ptr, "##tree_filter", -1)
        render_menu_bar(ui_state)
        ig.Columns(2, "main_layout")
        ig.BeginChild("Tree", (0, 0), true)
        if haskey(ui_state, :hierarchy_root)
            if ig.BeginTable("tree_table", 1, ig.ImGuiTableFlags_RowBg | ig.ImGuiTableFlags_ScrollY)
                for child in children(ui_state[:hierarchy_root])
                    render_node(child, String[], false)
                end
                ig.EndTable()
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
    ig.set_backend(:GlfwOpenGL3)
    ctx = ig.CreateContext()
    io = ig.GetIO()
    io.ConfigFlags = unsafe_load(io.ConfigFlags) | ig.ImGuiConfigFlags_DockingEnable
    io.ConfigFlags = unsafe_load(io.ConfigFlags) | ig.ImGuiConfigFlags_ViewportsEnable
    ig.StyleColorsDark()
    ui_state = Dict{Symbol,Any}()
    if root_path !== nothing && root_path != ""
        hierarchy = scan_directory(root_path)
        ui_state[:hierarchy_root] = hierarchy.root
        ui_state[:all_measurements] = hierarchy.all_measurements
        ui_state[:root_path] = root_path
    end
    ig.render(ctx; engine, window_size=(1280, 720), window_title="Measurement Browser", spawn) do
        render_device_tree(ui_state)
        render_info_window(ui_state)
        render_plot_window(ui_state)
    end
end

# Entry point
function start_browser(root_path::Union{Nothing,String}=nothing)
    create_window_and_run_loop(root_path)
end