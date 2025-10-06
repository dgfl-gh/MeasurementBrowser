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
                    # Collect device-level metadata keys (union)
                    all_params = Set{Symbol}()
                    for m in hierarchy.all_measurements
                        for k in keys(m.device_info.parameters)
                            push!(all_params, k)
                        end
                    end
                    ui_state[:device_metadata_keys] = sort!(collect(all_params); by=String)
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
            if ig.MenuItem("Debug Plot Mode", C_NULL, get(ui_state, :debug_plot_mode, false))
                ui_state[:debug_plot_mode] = !get(ui_state, :debug_plot_mode, false)
                # Invalidate cached figures when toggled
                delete!(ui_state, :plot_figure)
                delete!(ui_state, :_last_plotted_path)
                delete!(ui_state, :_last_plotted_mtime)
                # Invalidate additional plot windows
                # (disabled for now since we want to print from the active figure only, usually)
                # if haskey(ui_state, :open_plot_windows)
                #     for entry in ui_state[:open_plot_windows]
                #         if haskey(entry, :figure)
                #             delete!(entry, :figure)
                #         end
                #     end
                # end
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

    meta_keys = get(ui_state, :device_metadata_keys, Symbol[])

    # Local helpers tied to filter object
    node_matches(node::HierarchyNode) = ig.ImGuiTextFilter_PassFilter(filter_tree, node.name, C_NULL)
    subtree_match(node::HierarchyNode) = node_matches(node) || any(subtree_match(c) for c in children(node))

    function render_node(node::HierarchyNode, path::Vector{String}=String[], force_show::Bool=false)
        # return if neither the node nor any of its descendants match the filter
        force_show || subtree_match(node) || return

        ui_state[:_node_count] += 1
        ig.TableNextRow()
        ig.TableSetColumnIndex(0)

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
            ig.ImGuiTreeNodeFlags_DrawLinesToNodes |
            ig.ImGuiTreeNodeFlags_SpanAllColumns
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

        # Fill metadata columns
        dev_meta = nothing
        if is_leaf && !isempty(node.measurements)
            dev_meta = first(node.measurements).device_info.parameters
        end
        for (i, k) in enumerate(meta_keys)
            ig.TableSetColumnIndex(i)
            if dev_meta !== nothing && haskey(dev_meta, k)
                ig.Text(string(dev_meta[k]))
            elseif is_leaf
                ig.TextDisabled("--")
            else
                # non-leaf left blank
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
        local table_flags = ig.ImGuiTableFlags_BordersV | ig.ImGuiTableFlags_BordersOuterH |
                            ig.ImGuiTableFlags_Resizable | ig.ImGuiTableFlags_RowBg |
                            ig.ImGuiTableFlags_Reorderable | ig.ImGuiTableFlags_Hideable
        ncols = 1 + length(meta_keys) + 1
        if ig.BeginTable("tree_table", ncols, table_flags)
            local index_flags = ig.ImGuiTableColumnFlags_NoHide | ig.ImGuiTableColumnFlags_NoReorder |
                                ig.ImGuiTableColumnFlags_NoSort | ig.ImGuiTableColumnFlags_WidthStretch
            ig.TableSetupColumn("Device", index_flags, 5.0)
            for k in meta_keys
                ig.TableSetupColumn(String(k), ig.ImGuiTableColumnFlags_AngledHeader | ig.ImGuiTableFlags_SizingFixedFit)
            end
            ig.TableSetupColumn("")
            ig.TableAngledHeadersRow()
            ig.TableHeadersRow()
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
                     ig.ImGuiTextFilter_PassFilter(filter_meas, display_label(m), C_NULL) ||
                     ig.ImGuiTextFilter_PassFilter(filter_meas, m.clean_title, C_NULL) ||
                     ig.ImGuiTextFilter_PassFilter(filter_meas, measurement_label(m.measurement_kind), C_NULL)
            passes || continue
            any_shown = true
            selected = get(ui_state, :selected_measurement, nothing) == m
            if ig.Selectable(display_label(m), selected)
                ui_state[:selected_measurement] = m
            end
            # Right-click context menu per measurement entry
            if ig.BeginPopupContextItem()
                if ig.MenuItem("Open Plot in New Window")
                    open_plots = get!(ui_state, :open_plot_windows) do
                        Vector{Dict{Symbol,Any}}()
                    end
                    push!(open_plots, Dict(
                        :filepath => m.filepath,
                        :title => m.clean_title,
                        :params => deepcopy(m.device_info.parameters),
                    ))
                end
                ig.EndPopup()
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

# Unified helper: ensure (and cache) a Figure for a filepath with params
function _ensure_plot_figure(ui_state, filepath; kind=nothing, params...)
    # Produce a fresh Figure every time this is called (caller controls call frequency).
    # Avoid caching and reusing the same Figure object across multiple ImGui/Makie
    # windows because sharing a single GLMakie.Figure/Screen texture in multiple
    # ImGui contexts can trigger crashes.
    isfile(filepath) || return nothing
    try
        if get(ui_state, :debug_plot_mode, false)
            @info "Debug mode is ON: plots pass DEBUG flag."
        end
        return figure_for_file(filepath, kind; DEBUG=get(ui_state, :debug_plot_mode, false), params...)
    catch err
        @warn "figure_for_file failed" filepath error = err
        return nothing
    end
end

function render_plot_window(ui_state)
    m = get(ui_state, :selected_measurement, nothing)
    if m !== nothing
        filepath = m.filepath
        mtime = Dates.unix2datetime(stat(filepath).mtime)
        last_path = get(ui_state, :_last_plotted_path, nothing)
        last_mtime = get(ui_state, :_last_plotted_mtime, nothing)
        if filepath != last_path || mtime != last_mtime
            fig = _ensure_plot_figure(ui_state, filepath; kind=detect_measurement_kind(m.filename), m.device_info.parameters...)
            if fig !== nothing
                ui_state[:plot_figure] = fig
                ui_state[:_last_plotted_path] = filepath
                ui_state[:_last_plotted_mtime] = mtime
            else
                delete!(ui_state, :plot_figure)
                delete!(ui_state, :_last_plotted_path)
                delete!(ui_state, :_last_plotted_mtime)
            end
        end
    end
    if ig.Begin("Plot Area")
        if get(ui_state, :debug_plot_mode, false)
            ig.TextColored((0.2, 0.8, 0.2, 1.0), "Debug Plot Mode")
            ig.SameLine()
            _helpmarker("Debug mode is ON: plots pass DEBUG flag.")
        end
        if haskey(ui_state, :plot_figure)
            f = ui_state[:plot_figure]
            _time!(ui_state, :makie_fig) do
                MakieFigure("measurement_plot", f; auto_resize_x=true, auto_resize_y=true)
            end
        else
            ig.Text("Plot failed to generate")
        end
        ig.Separator()
        if m === nothing
            ig.TextDisabled("Select a measurement to generate a plot")
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
                    Dict{Symbol,Any}()
                end
            end
            if !isempty(stats)
                ig.Text("Stats")
                ig.BulletText("Total: $(stats[:total_measurements])")
                ig.BulletText("Types: $(join(stats[:measurement_types], ", "))")
                if haskey(stats, :first_measurement)
                    ig.BulletText("First: $(stats[:first_measurement]) ")
                    ig.BulletText("Last:  $(stats[:last_measurement]) ")
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
            ig.BulletText("Type: $(measurement_label(m.measurement_kind))")
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
        ig.Text("No device metadata file (device_info.txt) was found.")
        ig.Separator()
        ig.TextWrapped("Create a simple text file named device_info.txt in the TOP folder you opened to add extra info (area, thickness, notes, etc.) for each device.")
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

# Render any additional plot windows opened via right-click context menu.
function render_additional_plot_windows(ui_state)
    open_plots = get(ui_state, :open_plot_windows, nothing)
    open_plots === nothing && return
    isempty(open_plots) && return
    to_keep = Vector{Dict{Symbol,Any}}()
    for entry in open_plots
        filepath = get(entry, :filepath, "")
        isempty(filepath) && continue
        if !isfile(filepath)
            continue
        end
        title = get(entry, :title, basename(filepath))
        # Refresh / create figure (per-window; no global shared Figure)
        mtime = Dates.unix2datetime(stat(filepath).mtime)
        existing_mtime = get(entry, :mtime, nothing)
        refresh = !haskey(entry, :figure) || existing_mtime != mtime
        if refresh
            k = detect_measurement_kind(basename(filepath))
            fig = haskey(entry, :params) ?
                  _ensure_plot_figure(ui_state, filepath; kind=k, entry[:params]...) :
                  _ensure_plot_figure(ui_state, filepath; kind=k)
            fig === nothing && continue
            entry[:figure] = fig
            entry[:mtime] = mtime
        end
        # Window (allow user to close)
        open_ref = Ref(true)
        if ig.Begin("Plot: $title###plot_window_$filepath", open_ref)
            if haskey(entry, :figure)
                f = entry[:figure]
                # Sanitize id for ImGui (avoid slashes)
                id_str = replace(filepath, '/' => '_')
                _time!(ui_state, :makie_fig) do
                    MakieFigure("measurement_plot_$id_str", f; auto_resize_x=true, auto_resize_y=true)
                end
            else
                ig.Text("No plot available")
            end
            ig.Separator()
            ig.TextDisabled(basename(filepath))
        end
        ig.End()
        open_ref[] && push!(to_keep, entry)
    end
    ui_state[:open_plot_windows] = to_keep
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
        all_params = Set{Symbol}()
        for m in hierarchy.all_measurements
            for k in keys(m.device_info.parameters)
                push!(all_params, k)
            end
        end
        ui_state[:device_metadata_keys] = sort!(collect(all_params); by=String)
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
        _time!(ui_state, :extra_plots) do
            render_additional_plot_windows(ui_state)
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
