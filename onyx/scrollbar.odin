package onyx

import "core:math/linalg"

Scrollbar_Info :: struct {
	using _:     Widget_Info,
	vertical:    bool,
	pos:         f32,
	travel:      f32,
	handle_size: f32,
	make_visible: bool,
}

Scrollbar_Result :: struct {
	using _: Widget_Result,
	pos:     Maybe(f32),
}

make_scrollbar :: proc(info: Scrollbar_Info, loc := #caller_location) -> Scrollbar_Info {
	info := info
	info.id = hash(loc)
	info.desired_size[1 - int(info.vertical)] = core.style.shape.scrollbar_thickness
	return info
}

add_scrollbar :: proc(info: ^Scrollbar_Info) -> bool{
	begin_widget(info) or_return
	defer end_widget()

	widget.draggable = true

	// Virtually swizzle coordinates
	// TODO: Remove this and actually swizzle them for better readability
	i, j := int(info.vertical), 1 - int(info.vertical)

	box := widget.box

	box.lo[j] += (box.hi[j] - box.lo[j]) * (0.5 * (1 - widget.hover_time))

	handle_size := min(info.handle_size, (box.hi[i] - box.lo[i]))
	travel := (box.hi[i] - box.lo[i]) - handle_size

	handle_box := Box{}
	handle_box.lo[i] = box.lo[i] + clamp(info.pos / info.travel, 0, 1) * travel
	handle_box.hi[i] = handle_box.lo[i] + handle_size

	handle_box.lo[j] = box.lo[j]
	handle_box.hi[j] = box.hi[j]

	if point_in_box(core.mouse_pos, widget.box) {
		hover_widget(widget)
	}
	widget.hover_time = animate(widget.hover_time, 0.15, .Hovered in widget.state)
	widget.focus_time = animate(widget.focus_time, 0.15, info.make_visible || .Hovered in widget.state)

	if widget.visible {
		draw_box_stroke(box, 1, fade(core.style.color.substance, widget.focus_time))
		draw_box_fill(box, fade(core.style.color.substance, 0.5 * widget.focus_time))
		draw_box_fill(handle_box, fade(core.style.color.content, 0.5 * widget.focus_time))
	}

	if .Pressed in widget.state {
		if .Pressed not_in widget.last_state {
			core.drag_offset = core.mouse_pos - handle_box.lo
		}
		result.pos =
			clamp(((core.mouse_pos[i] - core.drag_offset[i]) - box.lo[i]) / travel, 0, 1) *
			info.travel
	}

	end_widget()
	return
}

do_scrollbar :: proc(info: Scrollbar_Info, loc := #caller_location) -> Scrollbar_Result {
	return add_scrollbar(make_scrollbar(info, loc))
}
