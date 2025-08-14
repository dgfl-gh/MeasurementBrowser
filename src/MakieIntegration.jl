# NOTE: This file is yanked from CImGui.jl
# For some reason, it has terrible performance.
# Let's see if we can improve it.
module MakieImguiIntegration

import Printf: @sprintf
import Statistics: mean, std

import CImGui as ig
import ModernGL as gl
import GLFW
import GLMakie
import GLMakie.Makie as Makie
using PrecompileTools: @setup_workload, @compile_workload

export MakieFigure, ImMakieWindow, ImMakieFigure, destroy_context

# Represents a single Figure to be shown as an ImGui image texture
struct ImMakieWindow
    glfw_window::GLFW.Window # Only needed for supporting GLMakie requirements
end

mutable struct ImMakieFigure
    figure::GLMakie.Figure
    screen::GLMakie.Screen{ImMakieWindow}

    render_times::Vector{Float32}
    times_idx::Int
    was_dragging::Bool

    function ImMakieFigure(figure, screen)
        self = new(figure, screen, zeros(Float32, 20), 1, false)
    end
end

const makie_context = Dict{ig.ImGuiID,ImMakieFigure}()

function destroy_context()
    for imfigure in values(makie_context)
        empty!(imfigure.figure)
    end

    empty!(makie_context)
end

Base.isopen(window::ImMakieWindow) = isopen(window.glfw_window)
GLMakie.destroy!(::ImMakieWindow) = nothing
GLMakie.reopen!(screen::GLMakie.Screen{ImMakieWindow}) = screen
GLMakie.set_screen_visibility!(::GLMakie.Screen{ImMakieWindow}, ::Bool) = nothing
GLMakie.framebuffer_size(window::ImMakieWindow) = GLMakie.framebuffer_size(window.glfw_window)
GLMakie.scale_factor(window::ImMakieWindow) = GLMakie.scale_factor(window.glfw_window)
GLMakie.was_destroyed(window::ImMakieWindow) = GLMakie.was_destroyed(window.glfw_window)

# ShaderAbstractions support
GLMakie.ShaderAbstractions.native_switch_context!(x::ImMakieWindow) = GLFW.MakeContextCurrent(x.glfw_window)
GLMakie.ShaderAbstractions.native_context_alive(x::ImMakieWindow) = GLFW.is_initialized() && x.glfw_window != C_NULL

# This is called by GLMakie.display() to set up connections to GLFW for
# mouse/keyboard events etc. We disable it explicitly because we deliver the
# events in an immediate-mode fashion within MakieFigure().
GLMakie.connect_screen(::GLMakie.Scene, ::GLMakie.Screen{ImMakieWindow}) = nothing


# Also disable the corresponding disconnection methods
for f in (Makie.window_area, Makie.window_open,
    Makie.mouse_buttons, Makie.mouse_position,
    Makie.scroll,
    Makie.keyboard_buttons, Makie.unicode_input,
    Makie.dropped_files,
    Makie.hasfocus, Makie.entered_window,
    Makie.frame_tick)
    GLMakie.disconnect!(::GLMakie.Screen{ImMakieWindow}, ::typeof(f)) = nothing
end

function draw_figure_tooltip(cursor_pos, image_size)
    help_str = "(?)"
    text_size = ig.CalcTextSize(help_str)
    text_pos = (cursor_pos.x + image_size[1] - text_size.x, cursor_pos.y)
    ig.AddText(ig.GetWindowDrawList(), text_pos, ig.IM_COL32_WHITE, help_str)
    hovering = ig.IsMouseHoveringRect(text_pos, (text_pos[1] + text_size.x, text_pos[2] + text_size.y))

    if hovering && ig.BeginTooltip()
        ig.PushTextWrapPos(ig.GetFontSize() * 35.0)
        ig.TextUnformatted("""
            Controls:
            - Scroll to zoom
            - Click and drag to rectangle select a region to zoom to
            - Right click and drag to pan
            - {x/y} and scroll to zoom along the X/Y axes
            - Ctrl + left click to reset the limits

            And right-click for plot settings.
            """)
        ig.PopTextWrapPos()
        ig.EndTooltip()
    end
end

function draw_figure_stats(cursor_pos, imfigure)
    n_samples = length(imfigure.render_times)
    mean_time = mean(imfigure.render_times)
    std_time = std(imfigure.render_times)
    text = @sprintf("Avg. of last %i render times: %.5f ± %.5fs",
        n_samples, mean_time, std_time)
    ig.AddText(ig.GetWindowDrawList(), cursor_pos, ig.IM_COL32_WHITE, text)
end

function draw_axisscale_buttons(scale, ticks, idx)
    if ig.RadioButton("linear##$(idx)", scale[] === identity)
        scale[] = identity
    end
    ig.SameLine()
    if ig.RadioButton("log10##$(idx)", scale[] === Makie.pseudolog10)
        scale[] = Makie.pseudolog10
        # ticks[] = Makie.LogTicks(Makie.LinearTicks(5))
    end
end

function draw_popup(axis)
    if ig.BeginPopupContextItem()
        ig.Text("Axis settings")
        ig.Separator()

        ig.Text("X scale:")
        ig.SameLine()
        draw_axisscale_buttons(axis.xscale, axis.xticks, 1)

        ig.Text("Y scale:")
        ig.SameLine()
        draw_axisscale_buttons(axis.yscale, axis.yticks, 2)

        ig.EndPopup()
    end
end

function MakieFigure(title_id::String, f::GLMakie.Figure; auto_resize_x=true, auto_resize_y=false, tooltip=true, stats=false)
    ig.PushID(title_id)
    id = ig.GetID(title_id)

    if haskey(makie_context, id)
        imf = makie_context[id]
        if imf.figure !== f
            # Simple/safe replacement: reuse existing screen & context
            imf.figure = f
            scene = Makie.get_scene(f)
            scene.events.window_open[] = true
            display(imf.screen, f)
            imf.times_idx = 1
            @debug "replaced figure for " id
        end
    else
        window = ig.current_window()
        makie_window = ImMakieWindow(window)
        screen = GLMakie.Screen(; window=makie_window, start_renderloop=false)
        makie_context[id] = ImMakieFigure(f, screen)
        scene = Makie.get_scene(f)
        scene.events.window_open[] = true
        display(screen, f)
        @debug "created context for " id
    end

    imfigure = makie_context[id]
    scene = Makie.get_scene(imfigure.figure)

    region_avail = ig.GetContentRegionAvail()
    region_size = (Int(region_avail.x), Int(region_avail.y))
    scene_size = size(scene)
    new_size = (auto_resize_x ? region_size[1] : scene_size[1],
        auto_resize_y ? region_size[2] : scene_size[2])

    if scene_size != new_size && all(new_size .> 0)
        scene.events.window_area[] = GLMakie.Rect2i(0, 0, Int(new_size[1]), Int(new_size[2]))
        resize!(f, new_size[1], new_size[2])
    end

    GLMakie.poll_updates(imfigure.screen) # added to tell Makie to actually process the events
    do_render = GLMakie.requires_update(imfigure.screen)
    if do_render
        @debug "rendering frame"
        idx = mod1(imfigure.times_idx, length(imfigure.render_times))
        imfigure.render_times[idx] = @elapsed GLMakie.render_frame(imfigure.screen; resize_buffers=false)
    end

    # The color texture is what we need to render as an image. We add it to the
    # drawlist and then create an InvisibleButton of the same size to create a
    # space in the layout that can respond to key presses and clicks etc (which
    # a regular Image() can't do).
    color_buffer = imfigure.screen.framebuffer.buffers[:color]
    drawlist = ig.GetWindowDrawList()
    cursor_pos = ig.GetCursorScreenPos()
    image_size = size(color_buffer)
    ig.AddImage(drawlist,
        ig.ImTextureRef(ig.ImTextureID(color_buffer.id)),
        cursor_pos,
        (cursor_pos.x + image_size[1], cursor_pos.y + image_size[2]),
        (0, 1), (1, 0))

    # Draw tooltip
    if tooltip
        draw_figure_tooltip(cursor_pos, image_size)
    end
    if stats
        draw_figure_stats(cursor_pos, imfigure)
    end

    ig.InvisibleButton("figure_image", size(color_buffer))

    # Update the scene events
    if scene.events.hasfocus[] != ig.IsItemHovered()
        scene.events.hasfocus[] = ig.IsItemHovered()
    end
    if scene.events.entered_window[] != ig.IsItemHovered()
        scene.events.entered_window[] = ig.IsItemHovered()
    end

    io = ig.GetIO()
    if ig.IsItemHovered()
        # Update the mouse position
        pos = ig.GetMousePos()
        cursor_pos = ig.GetCursorScreenPos()
        item_spacing = unsafe_load(ig.GetStyle().ItemSpacing.y)
        new_pos = (pos.x - cursor_pos.x, abs(pos.y - cursor_pos.y) - item_spacing)
        if new_pos != scene.events.mouseposition[]
            scene.events.mouseposition[] = new_pos
            @debug "mouse position updated", scene.events.mouseposition
        end

        # Update the mouse buttons
        for (igkey, makiekey) in ((ig.ImGuiKey_MouseLeft, Makie.Mouse.left),
            (ig.ImGuiKey_MouseRight, Makie.Mouse.right))
            if ig.IsKeyPressed(igkey)
                scene.events.mousebutton[] = Makie.MouseButtonEvent(makiekey, Makie.Mouse.press)
                @debug "mouse button pressed event", scene.events.mousebutton
            elseif ig.IsKeyReleased(igkey)
                scene.events.mousebutton[] = Makie.MouseButtonEvent(makiekey, Makie.Mouse.release)
                @debug "mouse button released event", scene.events.mousebutton
            end
        end

        # Record if the mouse is dragging
        if ig.IsMouseDragging(ig.lib.ImGuiMouseButton_Right)
            imfigure.was_dragging = true
        end

        # Update the scroll rat
        wheel_y = unsafe_load(io.MouseWheel)
        wheel_x = unsafe_load(io.MouseWheelH)
        if (wheel_x, wheel_y) != scene.events.scroll[]
            scene.events.scroll[] = (wheel_x, wheel_y)
            @debug "scrolling" scene.events.scroll
        end

        # Update pressed and released keys. For now we only support X/Y/left
        # Ctrl because those are the ones that Makie uses by default and to do
        # it properly for all keys we need to make a mapping from ImGuiKey's to
        # GLFW keys.
        for (igkey, glfwkey) in ((ig.lib.ImGuiKey_X, Int(GLFW.KEY_X)),
            (ig.lib.ImGuiKey_Y, Int(GLFW.KEY_Y)),
            (ig.lib.ImGuiKey_LeftCtrl, Int(GLFW.KEY_LEFT_CONTROL)))
            if ig.IsKeyPressed(igkey)
                scene.events.keyboardbutton[] = Makie.KeyEvent(Makie.Keyboard.Button(glfwkey), Makie.Keyboard.press)
                @debug "keyboard button pressed event", scene.events.keyboardbutton
            elseif ig.IsKeyReleased(igkey)
                scene.events.keyboardbutton[] = Makie.KeyEvent(Makie.Keyboard.Button(glfwkey), Makie.Keyboard.release)
                @debug "keyboard button released event", scene.events.keyboardbutton
            end
        end
    end

    # Always clear the dragging field when a new potential drag (right-click) is
    # started.
    if ig.IsMouseClicked(ig.lib.ImGuiMouseButton_Right)
        imfigure.was_dragging = false
    end

    # Only display the popup if we're not dragging
    if !imfigure.was_dragging
        for x in f.content
            if x isa Makie.Axis && GLMakie.is_mouseinside(x)
                draw_popup(x)
            end
        end
    end

    ig.PopID()

    return do_render
end

function theme_imgui()
    theme = Makie.theme_light()
    # theme = Makie.theme_dark()
    theme.Legend.framevisible = true
    # theme.Legend.backgroundcolor = Makie.RGBAf(0, 0, 0, 0.75)
    theme.Legend.padding = (5, 5, 5, 5)
    # theme.textcolor = :gray90

    # For some reason FXAA causes artifacts with the dark theme
    theme.GLMakie = Makie.Attributes(fxaa=false)

    return theme
end

function __init__()
    ig.atrenderexit(destroy_context)
    Makie.set_theme!(theme_imgui())
end

@setup_workload begin
    f = GLMakie.Figure()
    GLMakie.lines(f[1, 1], rand(10))

    @compile_workload begin
        ig.set_backend(:GlfwOpenGL3)
        ctx = ig.CreateContext()

        ig.render(ctx; window_title="CImGui/Makie precompilation workload", opengl_version=v"3.3") do
            ig.Begin("Foo")
            MakieFigure("plot", f)
            ig.End()

            return :imgui_exit_loop
        end

        destroy_context()
        ig._backend = nothing
    end
end

end
