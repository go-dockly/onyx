package onyx

import "../vgo"
import "base:intrinsics"
import "base:runtime"
import "core:container/small_array"
import "core:fmt"
import "core:math"
import "core:math/ease"
import "core:math/linalg"
import "core:mem"
import "core:reflect"
import "core:strings"
import "core:time"
import "tedit"

MAX_CLICK_DELAY :: time.Millisecond * 450

Object_Flag :: enum {
	Is_Input,
	Persistent,
}

Object_Flags :: bit_set[Object_Flag;u8]

Object_Status :: enum {
	Hovered,
	Focused,
	Pressed,
	Changed,
	Clicked,
	Open,
	Active,
	Dragged,
}

Object_State :: bit_set[Object_Status;u8]

OBJECT_STATE_ALL :: Object_State{.Hovered, .Focused, .Pressed, .Changed, .Clicked, .Open, .Active}

Object_Variant :: union {
	Button,
	Boolean,
	Container,
	Layout,
	Label,
	Input,
	Slider,
}

Object :: struct {
	id:             Id,
	index:          int,
	box:            Box,
	layer:          ^Layer,
	frames:         int,
	dead:           bool,
	disabled:       bool,
	has_known_box:  bool,
	flags:          Object_Flags,
	last_state:     Object_State,
	next_state:     Object_State,
	state:          Object_State,
	in_state_mask:  Object_State,
	out_state_mask: Object_State,
	click_count:    int,
	click_time:     time.Time,
	click_point:    [2]f32,
	click_button:   Mouse_Button,
	margin:         [4]f32,
	size:           [2]f32,
	desired_size:   [2]f32,
	variant:        Object_Variant,
}

Object_States :: struct {
	previous: Object_State,
	current:  Object_State,
	next:     Object_State,
	in_mask:  Object_State,
	out_mask: Object_State,
}

Object_Margin :: struct {
	left, right, top, bottom: f32,
}

clean_up_objects :: proc() {
	for object, index in global_state.objects {
		if object.dead {
			destroy_object(object)
			delete_key(&global_state.object_map, object.id)
			ordered_remove(&global_state.objects, index)
			free(object)
			draw_frames(1)
		} else {
			object.dead = true
		}
	}
	small_array.clear(&global_state.transient_objects)
}

animate :: proc(value, duration: f32, condition: bool) -> f32 {
	value := value

	if condition {
		if value < 1 {
			draw_frames(1)
			draw_frames(1)
			value = min(1, value + global_state.delta_time * (1 / duration))
		}
	} else if value > 0 {
		draw_frames(1)
		draw_frames(1)
		value = max(0, value - global_state.delta_time * (1 / duration))
	}

	return value
}

update_object_references :: proc() {
	global_state.last_focused_object = global_state.focused_object
	global_state.last_hovered_object = global_state.hovered_object

	if global_state.dragged_object != 0 {
		global_state.hovered_object = global_state.dragged_object
	} else {
		global_state.hovered_object = global_state.next_hovered_object
	}

	global_state.next_hovered_object = 0

	if (global_state.mouse_bits - global_state.last_mouse_bits) > {} {
		global_state.focused_object = global_state.hovered_object
	}
}

enable_objects :: proc(enabled: bool = true) {
	global_state.disable_objects = !enabled
}

current_object :: proc() -> Maybe(^Object) {
	if global_state.object_stack.height > 0 {
		return global_state.object_stack.items[global_state.object_stack.height - 1]
	}
	return nil
}

new_persistent_object :: proc(id: Id) -> ^Object {
	object := new(Object)

	assert(object != nil)

	object.id = id
	object.out_state_mask = OBJECT_STATE_ALL

	append(&global_state.objects, object)
	global_state.object_map[id] = object
	draw_frames(1)

	return object
}

destroy_object :: proc(object: ^Object) {
	#partial switch &v in object.variant {
	case Input:
		destroy_input(&v)
	case:
		break
	}
}

persistent_object :: proc(id: Id) -> ^Object {
	return global_state.object_map[id] or_else new_persistent_object(id)
}

transient_object :: proc() -> ^Object {
	small_array.append(&global_state.transient_objects, Object{})
	object :=
		small_array.get_ptr_safe(
			&global_state.transient_objects,
			global_state.transient_objects.len - 1,
		) or_else nil
	assert(object != nil)
	object.id = Id(global_state.transient_objects.len)
	return object
}

object_was_updated_this_frame :: proc(object: ^Object) -> bool {
	return object.frames >= global_state.frames
}

handle_object_click :: proc(object: ^Object, sticky: bool = false) {
	if global_state.hovered_object == object.id {
		// Add hovered state
		object.state += {.Hovered}
		// Clicking
		pressed_buttons := global_state.mouse_bits - global_state.last_mouse_bits
		if pressed_buttons != {} {
			if object.click_button == global_state.mouse_button &&
			   time.since(object.click_time) <= MAX_CLICK_DELAY {
				object.click_count = max((object.click_count + 1) % 4, 1)
			} else {
				object.click_count = 1
			}
			object.click_button = global_state.mouse_button
			object.click_point = global_state.mouse_pos
			object.click_time = time.now()
			object.state += {.Pressed}
			draw_frames(1)
			global_state.focused_object = object.id
			if sticky do global_state.dragged_object = object.id
		}
		// TODO: Lose click if mouse moved too much (allow for dragging containers by their contents)
		// if !info.sticky && linalg.length(core.click_mouse_pos - core.mouse_pos) > 8 {
		// 	object.state -= {.Pressed}
		// 	object.click_count = 0
		// }
	} else if global_state.dragged_object != object.id {
		object.state -= {.Pressed, .Hovered}
		object.click_count = 0
	}
	if object.state >= {.Pressed} {
		released_buttons := global_state.last_mouse_bits - global_state.mouse_bits
		if object.click_button in released_buttons {
			object.state += {.Clicked}
			object.state -= {.Pressed, .Dragged}
			global_state.dragged_object = 0
		}
	} else {
		if object.click_count > 0 &&
		   linalg.length(global_state.mouse_pos - global_state.last_mouse_pos) > 2 {
			object.click_count = 0
		}
	}
}

object_is_visible :: proc(object: ^Object) -> bool {
	return global_state.visible && get_clip(object.layer.box, object.box) != .Full
}

update_object_state :: proc(object: ^Object) {
	object.last_state = object.state

	object.state -= {.Clicked, .Focused, .Changed}
	if global_state.focused_object == object.id {
		object.state += {.Focused}
	}

	object.state += object.next_state
	object.next_state = {}
}

begin_object :: proc(object: ^Object) -> bool {
	assert(object != nil)

	object.index = global_state.object_index
	global_state.object_index += 1

	object.dead = false

	if object_was_updated_this_frame(object) {
		when ODIN_DEBUG {
			fmt.printfln("Object ID collision: %i", object.id)
		}
		return false
	}
	object.frames = global_state.frames

	object.layer = current_layer().? or_return
	update_object_state(object)
	if global_state.disable_objects do object.disabled = true

	if layout, ok := current_layout().?; ok {
		object.margin = layout.object_margin
		// If the user set an explicit size with either `set_width()` or `set_height()` the object's desired size should reflect that
		// The purpose of these checks is that `set_size_fill()` makes content shrink to accommodate scrollbars
		if layout.object_size.x == 0 || layout.object_size.x != box_width(layout.content_box) {
			object.desired_size.x = max(object.desired_size.x, layout.object_size.x)
		}
		if layout.object_size.y == 0 || layout.object_size.y != box_height(layout.content_box) {
			object.desired_size.y = max(object.desired_size.y, layout.object_size.y)
		}
	}

	push_stack(&global_state.object_stack, object) or_return

	return true
}

end_object :: proc() {
	if object, ok := current_object().?; ok {
		if layout, ok := current_layout().?; ok {
			object.size = linalg.max(object.size, object.desired_size, layout.object_size)
			effective_size := object.desired_size + object.margin.xy + object.margin.zw
			switch layout.axis {
			case .X:
				layout.content_size.x += effective_size.x
				layout.content_size.y = max(layout.content_size.y, effective_size.y)
			case .Y:
				layout.content_size.y += effective_size.y
				layout.content_size.x = max(layout.content_size.x, effective_size.x)
			}
			display_or_add_object(object, layout)
		} else {
			display_object(object)
		}
		object.layer.state += object.state
		pop_stack(&global_state.object_stack)
		if parent, ok := current_object().?; ok {
			transfer_object_state_to_parent(object, parent)
		}
	}
}

transfer_object_state_to_parent :: proc(child: ^Object, parent: ^Object) {
	state_mask := child.out_state_mask & parent.in_state_mask
	if .Pressed in child.state && child.id == global_state.dragged_object {
		state_mask -= {.Pressed}
	}
	parent.next_state += child.next_state & state_mask
}

hover_object :: proc(object: ^Object) {
	when DEBUG {
		if global_state.debug.enabled do return
	}
	if object.disabled do return
	if object.layer.index < global_state.hovered_layer_index do return
	if !point_in_box(global_state.mouse_pos, object.layer.box) do return
	global_state.next_hovered_object = object.id
	global_state.next_hovered_layer = object.layer.id
	global_state.hovered_layer_index = object.layer.index
}

focus_object :: proc(object: ^Object) {
	global_state.focused_object = object.id
}

foreground :: proc(loc := #caller_location) {
	layout, ok := current_layout().?
	if !ok do return
	object := persistent_object(hash(loc))
	if begin_object(object) {
		defer end_object()
		if object.variant == nil {
			object.in_state_mask = OBJECT_STATE_ALL
		}
		object.box = layout.box
		vgo.fill_box(object.box, global_state.style.rounding, paint = global_state.style.color.fg)
		if point_in_box(global_state.mouse_pos, object.box) {
			hover_object(object)
		}
	}
}

background :: proc(loc := #caller_location) {
	layout, ok := current_layout().?
	if !ok do return
	object := persistent_object(hash(loc))
	if begin_object(object) {
		defer end_object()
		if object.variant == nil {
			object.in_state_mask = OBJECT_STATE_ALL
		}
		object.box = layout.box
		vgo.fill_box(object.box, global_state.style.rounding, global_state.style.color.field)
		if point_in_box(global_state.mouse_pos, object.box) {
			hover_object(object)
		}
	}
}

spinner :: proc(loc := #caller_location) {
	object := persistent_object(hash(loc))
	if begin_object(object) {
		defer end_object()

		vgo.spinner(
			box_center(object.box),
			box_height(object.box) * 0.5,
			global_state.style.color.substance,
		)
	}
}

draw_skeleton :: proc(box: Box, rounding: f32) {
	vgo.fill_box(box, rounding, global_state.style.color.substance)
	vgo.fill_box(box, rounding, vgo.Paint{kind = .Skeleton})

	draw_frames(1)
}

object_is_in_front_of :: proc(object: ^Object, other: ^Object) -> bool {
	if (object == nil) || (other == nil) do return true
	return (object.index > other.index) && (object.layer.index >= other.layer.index)
}

display_object :: proc(object: ^Object) {
	when DEBUG {
		if point_in_box(mouse_point(), object.box) {
			if object_is_in_front_of(object, top_hovered_object(global_state.debug) or_else nil) {
				global_state.debug.top_object_index = len(global_state.debug.hovered_objects)
			}
			append(&global_state.debug.hovered_objects, object)
		}
	}

	switch &v in object.variant {
	case Container:
	case Input:
		display_input(&v)
	case Button:
		display_button(&v)
	case Boolean:
		display_boolean(&v)
	case Layout:
		display_layout(&v)
	case Label:
		display_label(&v)
	case Slider:
		display_slider(&v)
	}
}
