import GLFW
using GLMakie
import GLMakie.Makie as Makie
import CImGui as ig
import CImGui.CSyntax: @c
import ModernGL as gl
using Printf

using Statistics: mean

include("MakieIntegration.jl")
using .MakieImguiIntegration

include("PlotGenerator.jl")
using .PlotGenerator

# Timing & allocation utilities
# usage: _time!(ui_state, :key) do ... end
function _time!(f::Function, ui_state, key::Symbol)
    timings = get!(() -> Dict{Symbol,Vector{Float64}}(), ui_state, :_timings)
    allocs = get!(() -> Dict{Symbol,Vector{Int}}(), ui_state, :_allocs)
    t0 = time_ns()
    bytes = @allocated f()
    dt_ms = (time_ns() - t0) / 1e6
    vec = get!(() -> Float64[], timings, key)
    push!(vec, dt_ms)
    length(vec) > 400 && popfirst!(vec)
    avec = get!(() -> Int[], allocs, key)
    push!(avec, bytes)
    length(avec) > 400 && popfirst!(avec)
    nothing
end

function _collect_gl_info!()
    try
        Dict(
            :vendor => unsafe_string(gl.glGetString(gl.GL_VENDOR)),
            :renderer => unsafe_string(gl.glGetString(gl.GL_RENDERER)),
            :version => unsafe_string(gl.glGetString(gl.GL_VERSION)),
            :sl => unsafe_string(gl.glGetString(gl.GL_SHADING_LANGUAGE_VERSION)),
        )
    catch err
        @warn "GL info query failed" error = err
        Dict{Symbol,String}()
    end
end

function _print_perf_summary(ui_state)
    @debug begin
        gi = ui_state[:_gl_info]
        timings = get(ui_state, :_timings, Dict{Symbol,Vector{Float64}}())
        allocs = get(ui_state, :_allocs, Dict{Symbol,Vector{Int}}())
        msg = """\n
        ==== Performance Summary ====
        GL Vendor:   $(get(gi, :vendor, "?"))
        GL Renderer: $(get(gi, :renderer, "?"))
        GL Version:  $(get(gi, :version, "?"))
        """
        if !isempty(timings)
            msg = msg * @sprintf "%-12s %5s %9s %9s %9s %12s %12s\n" "Key" "n" "Mean(ms)" "Max(ms)" "Last(ms)" "AllocMean(KB)" "AllocLast(KB)"
        end
        for k in sort(collect(keys(timings)))
            v = timings[k]
            isempty(v) && continue
            a = get(allocs, k, Int[])
            n = length(v)
            mean_ms = mean(v)
            max_ms = maximum(v)
            last_ms = v[end]
            mean_alloc = isempty(a) ? 0.0 : mean(a) / 1024
            last_alloc = isempty(a) ? 0.0 : a[end] / 1024
            msg = msg * @sprintf "%-12s %5d %9.2f %9.2f %9.2f %12.1f %12.1f\n" String(k) n mean_ms max_ms last_ms mean_alloc last_alloc
        end
        msg * "=============================="
    end
end

function _helpmarker(desc::String)
    ig.TextDisabled("(?)")
    if ig.BeginItemTooltip()
        ig.PushTextWrapPos(ig.GetFontSize() * 35.0)
        ig.TextUnformatted(desc)
        ig.PopTextWrapPos()
        ig.EndTooltip()
    end
end

function render_perf_window(ui_state)
    if !get(ui_state, :show_performance_window, false)
        return
    end

    if ig.Begin("Performance")
        raw_io = ig.GetIO()
        fps = unsafe_load(raw_io.Framerate)
        if fps > 0
            ig.Text(
                "FPS: $(round(fps; digits=1))  Frame: " *
                "$(round(1000 / fps; digits=2)) ms"
            )
        end

        if haskey(ui_state, :_gl_info)
            gi = ui_state[:_gl_info]
            for k in (:vendor, :renderer, :version)
                haskey(gi, k) && ig.Text("GL $(k): $(gi[k])")
            end
        end

        if haskey(ui_state, :_node_count)
            ig.Text("Tree nodes rendered: $(ui_state[:_node_count])")
        end

        timings = get(ui_state, :_timings,
            Dict{Symbol,Vector{Float64}}())
        allocs = get(ui_state, :_allocs,
            Dict{Symbol,Vector{Int}}())

        for (k, v) in timings
            isempty(v) && continue
            a = get(allocs, k, Int[])
            last_ms = round(v[end]; digits=2)
            mean_ms = round(mean(v); digits=2)
            last_alloc = isempty(a) ? 0.0 : round(a[end] / 1024; digits=1)
            mean_alloc = isempty(a) ? 0.0 : round(mean(a) / 1024; digits=1)
            msg = @sprintf "%s: last=%.2f ms  mean=%.2f ms  alloc_last=%.1f KB  alloc_mean=%.1f KB" String(k) last_ms mean_ms last_alloc mean_alloc

            ig.BulletText(msg)
        end

        if ig.Button("Clear timings")
            empty!(get!(() -> Dict{Symbol,Vector{Float64}}(), ui_state, :_timings))
            empty!(get!(() -> Dict{Symbol,Vector{Int}}(), ui_state, :_allocs))
        end
    end
    ig.End()
end

function render_main_window(ui_state)
    if ig.Begin("Measurement Browser", C_NULL,
        ig.ImGuiWindowFlags_MenuBar)
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
                end
                if !isnothing(path) && !isempty(path)
                    @info "Selected path: $path"
                    hierarchy = scan_directory(path)
                    ui_state[:hierarchy_root] = hierarchy.root
                    ui_state[:all_measurements] = hierarchy.all_measurements
                    ui_state[:root_path] = path
                    ui_state[:has_device_metadata] = hierarchy.has_device_metadata
                end
            end
            ig.EndMenu()
        end
        if ig.BeginMenu("Debug")
            if ig.MenuItem("Performance Window")
                if !get(ui_state, :show_performance_window, false)
                    ui_state[:show_performance_window] = true
                else
                    ui_state[:show_performance_window] = false
                end
            end
            ig.EndMenu()
        end
        ig.EndMenuBar()
    end
end

# Left panel (hierarchy tree) rendering
function _render_hierarchy_tree_panel(ui_state, filter_tree)
    ig.BeginChild("Tree", (0, 0), true)
    ig.SeparatorText("Device Selection")
    ig.Text("Filter")
    ig.SameLine()
    _helpmarker("incl,-excl")
    ig.SameLine()
    ig.SetNextItemShortcut(
        ig.ImGuiMod_Ctrl | ig.ImGuiKey_F,
        ig.ImGuiInputFlags_Tooltip
    )
    ig.ImGuiTextFilter_Draw(filter_tree, "##tree_filter", -1)

    # Local helpers tied to filter object
    node_matches(node::HierarchyNode) = ig.ImGuiTextFilter_PassFilter(filter_tree, node.name, C_NULL)
    subtree_match(node::HierarchyNode) = node_matches(node) || any(subtree_match(c) for c in children(node))

    function render_node(node::HierarchyNode, path::Vector{String}=String[], force_show::Bool=false)
        # return if neither the node nor any of its descendants match the filter
        force_show || subtree_match(node) || return

        ui_state[:_node_count] += 1
        ig.TableNextRow()
        ig.TableNextColumn()

        full_path = vcat(path, node.name)
        direct_match = force_show || node_matches(node)
        unique_id = join(full_path, "/")
        ig.PushID(unique_id)

        # appearance flags
        is_leaf = isempty(children(node))
        selected = get(ui_state, :selected_path, String[]) == full_path
        flags = (
            ig.ImGuiTreeNodeFlags_OpenOnArrow |
            ig.ImGuiTreeNodeFlags_OpenOnDoubleClick |
            ig.ImGuiTreeNodeFlags_NavLeftJumpsToParent |
            ig.ImGuiTreeNodeFlags_SpanFullWidth |
            ig.ImGuiTreeNodeFlags_DrawLinesToNodes
        )
        if is_leaf
            flags |= (
                ig.ImGuiTreeNodeFlags_Leaf |
                ig.ImGuiTreeNodeFlags_Bullet |
                ig.ImGuiTreeNodeFlags_NoTreePushOnOpen
            )
        end
        if selected
            flags |= ig.ImGuiTreeNodeFlags_Selected
        end
        if ig.ImGuiTextFilter_IsActive(filter_tree) && direct_match && !is_leaf
            flags |= ig.ImGuiTreeNodeFlags_DefaultOpen
        end

        opened = ig.TreeNodeEx(is_leaf ? "" : node.name, flags, node.name)
        # when a leaf (device) is clicked, select its measurements
        if ig.IsItemClicked() || ig.IsItemFocused()
            ui_state[:selected_path] = full_path
            if is_leaf
                ui_state[:selected_device] = node
            elseif haskey(ui_state, :selected_device)
                delete!(ui_state, :selected_device)
            end
        end
        # render children
        if opened && !is_leaf
            for c in children(node)
                render_node(c, full_path, direct_match)
            end
            ig.TreePop()
        end
        ig.PopID()
    end

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
end

# Right panel (measurements list) rendering
function _render_measurements_panel(ui_state, filter_meas)
    ig.BeginChild("Measurements", (0, 0), true)
    ig.SeparatorText("Measurement Selection")
    ig.Text("Filter")
    ig.SameLine()
    _helpmarker("incl,-excl")
    ig.SameLine()
    ig.SetNextItemShortcut(
        ig.ImGuiMod_Ctrl | ig.ImGuiKey_F,
        ig.ImGuiInputFlags_Tooltip
    )
    ig.ImGuiTextFilter_Draw(filter_meas, "##measurements_filter", -1)

    if haskey(ui_state, :selected_device)
        meas_vec = ui_state[:selected_device].measurements
        sel_name = join(get(ui_state, :selected_path, [""]), "/")
        ig.Text("Measurements for $sel_name")
        ig.Separator()
        any_shown = false
        for m in meas_vec
            passes = !ig.ImGuiTextFilter_IsActive(filter_meas) ||
                     ig.ImGuiTextFilter_PassFilter(filter_meas, meas_id(m), C_NULL) ||
                     ig.ImGuiTextFilter_PassFilter(filter_meas, m.clean_title, C_NULL) ||
                     ig.ImGuiTextFilter_PassFilter(filter_meas, m.measurement_type, C_NULL)
            passes || continue
            any_shown = true
            selected = get(ui_state, :selected_measurement, nothing) == m
            if ig.Selectable(meas_id(m), selected)
                ui_state[:selected_measurement] = m
            end
        end
        !any_shown && ig.TextDisabled("No measurements match filter")
    else
        ig.Text("Select a device to view measurements")
    end
    ig.EndChild()
end

function render_selection_window(ui_state)
    ui_state[:_node_count] = 0
    filter_tree = get!(ui_state, :_imgui_text_filter_tree) do
        ig.ImGuiTextFilter_ImGuiTextFilter(C_NULL)
    end
    filter_meas = get!(ui_state, :_imgui_text_filter_meas) do
        ig.ImGuiTextFilter_ImGuiTextFilter(C_NULL)
    end

    if ig.Begin("Hierarchy", C_NULL, ig.ImGuiWindowFlags_MenuBar)
        render_menu_bar(ui_state)
        ig.Columns(2, "main_layout")
        _render_hierarchy_tree_panel(ui_state, filter_tree)
        ig.NextColumn()
        _render_measurements_panel(ui_state, filter_meas)
    end
    ig.End()
end

function render_plot_window(ui_state)
    # Figure cache: filepath => (mtime, Figure)
    cache = get!(ui_state, :_plot_cache) do
        Dict{String,Tuple{DateTime,Figure}}()
    end
    m = get(ui_state, :selected_measurement, nothing)
    if m !== nothing
        filepath = m.filepath
        last_path = get(ui_state, :_last_plotted_path, nothing)
        # Determine modification time
        mtime = Dates.unix2datetime(stat(filepath).mtime)
        need_refresh = false
        if last_path !== filepath || !haskey(cache, filepath)
            need_refresh = true
            @debug "refreshing plot" need_refresh last_path filepath
        else
            cached_mtime, _ = cache[filepath]
            need_refresh = cached_mtime != mtime
        end
        if need_refresh
            newfig = figure_for_file(filepath; m.device_info.parameters...)
            @debug "Refreshing plot" newfig
            if newfig !== nothing
                cache[filepath] = (mtime, newfig)
                ui_state[:plot_figure] = newfig
                ui_state[:_last_plotted_path] = filepath
            else
                delete!(ui_state, :plot_figure)
                delete!(ui_state, :_last_plotted_path)
            end
        end
    end
    if ig.Begin("Plot Area")
        if haskey(ui_state, :plot_figure)
            f = ui_state[:plot_figure]
            _time!(ui_state, :makie_fig) do
                MakieFigure("measurement_plot", f; auto_resize_x=true, auto_resize_y=true)
            end
        else
            ig.Text("No plot available")
        end
        ig.Separator()
        if m === nothing
            ig.TextDisabled("Select a measurement to generate a plot")
        else
            ig.TextDisabled(basename(m.filepath))
        end
    end
    ig.End()
end

function render_info_window(ui_state)
    if ig.Begin("Information Panel")
        flags = ig.ImGuiTableFlags_Borders | ig.ImGuiTableFlags_RowBg | ig.ImGuiTableFlags_ScrollY
        ig.BeginTable("info_cols", 2, flags)
        ig.TableSetupColumn("Device")
        ig.TableSetupColumn("Measurement")
        ig.TableHeadersRow()
        ig.TableNextRow()
        ig.TableNextColumn()

        if haskey(ui_state, :selected_device)
            meas_vec = ui_state[:selected_device].measurements
            sel_name = join(get(ui_state, :selected_path, [""]), "/")
            ig.Text("Location: $sel_name")
            ig.Separator()
            stats = begin
                try
                    get_measurements_stats(meas_vec)
                catch err
                    @warn "Failed to compute stats" error = err
                    Dict{String,Any}()
                end
            end
            if !isempty(stats)
                ig.Text("Stats")
                ig.BulletText("Total: $(stats["total_measurements"])")
                ig.BulletText("Types: $(join(stats["measurement_types"], ", "))")
                if haskey(stats, "first_measurement")
                    ig.BulletText("First: $(stats["first_measurement"]) ")
                    ig.BulletText("Last:  $(stats["last_measurement"]) ")
                end
            else
                ig.TextDisabled("No stats available")
            end
            ig.Separator()
            # Device-level metadata
            if !isempty(meas_vec)
                dev_meta = first(meas_vec).device_info.parameters
                if !isempty(dev_meta)
                    ig.Text("Device metadata")
                    for (k, v) in dev_meta
                        ig.BulletText("$(k): $(v)")
                    end
                else
                    ig.TextDisabled("No metadata parameters found")
                end
            end
        else
            ig.TextDisabled("Select a device to see details")
        end

        ig.TableNextColumn()
        if haskey(ui_state, :selected_measurement)
            m = ui_state[:selected_measurement]
            ig.Text("Title: $(m.clean_title)")
            ig.Separator()
            ig.BulletText("Type: $(m.measurement_type)")
            ig.BulletText("Timestamp: $(m.timestamp)")
            ig.BulletText("Filename:")
            ig.SameLine()
            ig.TextLinkOpenURL(m.filename, m.filepath)
            ig.Separator()
            if !isempty(m.parameters)
                ig.Text("Parameters")
                for (k, v) in m.parameters
                    ig.BulletText("$(k) = $(v)")
                end
            else
                ig.TextDisabled("No parameters extracted")
            end

        else
            ig.TextDisabled("Select a measurement to view details")
        end
        ig.EndTable()
    end
    ig.End()
end

# ------------------------------------------------------------------
# Modal for missing device metadata (shown each scan when missing)
# ------------------------------------------------------------------
function render_device_info_modal(ui_state)
    # Reset dismissal when root path changes
    current_root = get(ui_state, :root_path, "")
    if get(ui_state, :_modal_last_root_path, "") != current_root
        ui_state[:_modal_last_root_path] = current_root
        ui_state[:dev_info_modal] = true
    end
    # always center
    center = ig.ImVec2(0.5, 0.5)
    @c ig.ImGuiViewport_GetCenter(&center, ig.GetMainViewport())
    ig.SetNextWindowPos(center, ig.ImGuiCond_Always, (0.5, 0.5))

    # Show modal if: missing metadata and user hasn't dismissed it this scan
    if get(ui_state, :dev_info_modal, true) && !get(ui_state, :has_device_metadata, true)
        ig.OpenPopup("Device Metadata Missing")
    end

    opened = get(ui_state, :dev_info_modal, true)

    if @c ig.BeginPopupModal("Device Metadata Missing", &opened, ig.ImGuiWindowFlags_AlwaysAutoResize)
        ig.Text("No device metadata file (device_info.csv) was found.")
        ig.Separator()
        ig.TextWrapped("Create a simple CSV file named device_info.csv in the TOP folder you opened to add extra info (area, thickness, notes, etc.) for each device.")
        ig.Spacing()
        ig.TextWrapped("How to do it:")
        ig.BulletText("Create a new text file: device_info.txt")
        ig.BulletText("First line (header): device_path, area_um2, thickness_nm, ...")
        ig.BulletText("Add a column for each property you want to track.")
        ig.BulletText("Add one line per device. device_path can be just a name (A1) or a full path (CHIP1/SITE1/A2)")
        ig.BulletText("A full path entry overrides a simple name entry for the same leaf.")
        ig.Spacing()
        ig.TextDisabled("Example:")
        ig.TextDisabled("device,   area_um2,   thickness_nm,   notes,   active")
        ig.TextDisabled("A1,    12.5,   7.0,   baseline,   true")
        ig.TextDisabled("CHIP1/SITE1/A2,    12.4,   7.0,   override,  true")
        ig.Spacing()
        ig.TextWrapped("Save the file, then rescan or reopen the folder to load these values.")
        ig.Spacing()
        if ig.Button("Got it")
            opened = false
            ig.CloseCurrentPopup()
        end
        ig.EndPopup()
    end
    ui_state[:dev_info_modal] = opened
end

function create_window_and_run_loop(root_path::Union{Nothing,String}=nothing; engine=nothing, spawn=1)
    ig.set_backend(:GlfwOpenGL3)
    ui_state = Dict{Symbol,Any}()
    ui_state[:_frame] = 0
    ctx = ig.CreateContext()
    io = ig.GetIO()
    io.ConfigFlags = unsafe_load(io.ConfigFlags) | ig.ImGuiConfigFlags_DockingEnable
    io.ConfigFlags = unsafe_load(io.ConfigFlags) | ig.ImGuiConfigFlags_ViewportsEnable
    io.ConfigFlags = unsafe_load(io.ConfigFlags) | ig.ImGuiConfigFlags_NavEnableKeyboard
    ig.StyleColorsDark()
    if root_path !== nothing && root_path != ""
        hierarchy = scan_directory(root_path)
        ui_state[:hierarchy_root] = hierarchy.root
        ui_state[:all_measurements] = hierarchy.all_measurements
        ui_state[:root_path] = root_path
        ui_state[:has_device_metadata] = hierarchy.has_device_metadata
    end
    first_frame = Ref(true)
    ig.render(
        ctx;
        engine,
        window_size=(1920, 1080),
        window_title="Measurement Browser",
        opengl_version=v"3.3",
        spawn,
        wait_events=false,
        on_exit=() -> _print_perf_summary(ui_state),
    ) do
        ui_state[:_frame] += 1
        if first_frame[] && !haskey(ui_state, :_gl_info)
            ui_state[:_gl_info] = _collect_gl_info!()
            first_frame[] = false
            # try
            #     GLFW.SwapInterval(0)  # disable vsync
            # catch err
            #     @warn "Failed to disable vsync" error = err
            # end
        end
        ig.DockSpaceOverViewport(0, ig.GetMainViewport())
        _time!(ui_state, :device_tree) do
            render_selection_window(ui_state)
        end
        _time!(ui_state, :info) do
            render_info_window(ui_state)
        end
        _time!(ui_state, :plot) do
            render_plot_window(ui_state)
        end
        _time!(ui_state, :perf_window) do
            render_perf_window(ui_state)
        end
        # Show metadata guidance modal if needed
        render_device_info_modal(ui_state)
    end
end

function start_browser(root_path::Union{Nothing,String}=nothing)
    create_window_and_run_loop(root_path)
end
