package onyx

import "core:fmt"
import "core:slice"
import "core:strings"
import "core:time"
import "core:unicode"

Text_Input_Decal :: enum {
	None,
	Check,
	Loader,
}

Text_Input_Info :: struct {
	using _:                      Generic_Widget_Info,
	builder:                      ^strings.Builder,
	placeholder:                  string,
	auto_focus:                   bool,
	numeric, integer:             bool,
	multiline, read_only, hidden: bool,
	decal:                        Text_Input_Decal,
}

Text_Input_Widget_Kind :: struct {
	editor:    Text_Editor,
	anchor:    int,
	icon_time: f32,
}

Text_Input_Result :: struct {
	using _:            Generic_Widget_Result,
	changed, submitted: bool,
}

make_text_input :: proc(info: Text_Input_Info, loc := #caller_location) -> Text_Input_Info {
	info := info
	info.id = hash(loc)
	info.desired_size = {200, 30}
	return info
}

add_text_input :: proc(info: Text_Input_Info) -> (result: Text_Input_Result) {
	if info.builder == nil {
		return
	}

	widget, ok := begin_widget(info)
	if !ok do return

	widget.draggable = true
	widget.is_field = true

	result.self = widget

	variant := widget_kind(widget, Text_Input_Widget_Kind)
	e := &variant.editor

	widget.focus_time = animate(widget.focus_time, 0.15, .Focused in widget.state)
	variant.icon_time = animate(variant.icon_time, 0.2, info.decal != .None)

	// Hover cursor
	if .Hovered in widget.state {
		core.cursor_type = .I_Beam
	}

	// Hover
	if point_in_box(core.mouse_pos, widget.box) {
		hover_widget(widget)
	}

	// Receive and execute editor commands
	if .Focused in widget.state {
		cmd: Command
		control_down := key_down(.Left_Control) || key_down(.Right_Control)
		shift_down := key_down(.Left_Shift) || key_down(.Right_Shift)
		if control_down {
			if key_pressed(.A) do cmd = .Select_All
			if key_pressed(.C) do cmd = .Copy
			if key_pressed(.V) do cmd = .Paste
			if key_pressed(.X) do cmd = .Cut
			if key_pressed(.Z) do cmd = .Undo
			if key_pressed(.Y) do cmd = .Redo
		}
		// Write allowed and runes available?
		if !info.read_only && len(core.runes) > 0 {
			// Determine filter string
			allowed: string
			if info.numeric {
				allowed = "0123456789."
				if info.integer || strings.contains_rune(strings.to_string(info.builder^), '.') {
					allowed = allowed[:len(allowed) - 1]
				}
			}
			// Input filtered runes
			for char, c in core.runes {
				if len(allowed) > 0 && !strings.contains_rune(allowed, char) do continue
				input_runes(e, {char})
				result.changed = true
				core.draw_this_frame = true
			}
		}
		if key_pressed(.Backspace) do cmd = .Delete_Word_Left if control_down else .Backspace
		if key_pressed(.Delete) do cmd = .Delete_Word_Right if control_down else .Delete
		if key_pressed(.Enter) {
			cmd = .New_Line
			if info.multiline {
				if control_down {
					result.submitted = true
				}
			} else {
				result.submitted = true
			}
		}
		if key_pressed(.Left) {
			if shift_down do cmd = .Select_Word_Left if control_down else .Select_Left
			else do cmd = .Word_Left if control_down else .Left
		}
		if key_pressed(.Right) {
			if shift_down do cmd = .Select_Word_Right if control_down else .Select_Right
			else do cmd = .Word_Right if control_down else .Right
		}
		if key_pressed(.Up) {
			if shift_down do cmd = .Select_Up
			else do cmd = .Up
		}
		if key_pressed(.Down) {
			if shift_down do cmd = .Select_Down
			else do cmd = .Down
		}
		if key_pressed(.Home) {
			cmd = .Select_Line_Start if control_down else .Line_Start
		}
		if key_pressed(.End) {
			cmd = .Select_Line_End if control_down else .Line_End
		}
		if !info.multiline && (cmd in MULTILINE_COMMANDS) {
			cmd = .None
		}
		if info.read_only && (cmd in EDIT_COMMANDS) {
			cmd = .None
		}
		if cmd != .None {
			text_editor_execute(e, cmd)
			result.changed = true
			core.draw_this_frame = true
		}
	}

	// Initial text info
	text_info: Text_Info = {
		font   = core.style.fonts[.Medium],
		text   = strings.to_string(info.builder^),
		size   = core.style.content_text_size,
		hidden = info.hidden,
	}

	text_origin: [2]f32 = {widget.box.lo.x + 5, 0}

	// Offset text origin based on font size
	if font, ok := &core.fonts[text_info.font].?; ok {
		if font_size, ok := get_font_size(font, text_info.size); ok {
			if info.multiline {
				text_origin.y = widget.box.lo.y + (font_size.ascent - font_size.descent) / 2
			} else {
				text_origin.y =
					(widget.box.hi.y + widget.box.lo.y) / 2 -
					(font_size.ascent - font_size.descent) / 2
			}
		}
	}

	// Initialize editor state when just focused
	if .Focused in (widget.state - widget.last_state) {
		make_text_editor(e, widget.allocator, widget.allocator)
		begin(e, 0, info.builder)
		e.set_clipboard = set_clipboard_string
		e.get_clipboard = get_clipboard_string
	}

	// Make text job
	if text_job, ok := make_text_job(text_info, e, core.mouse_pos - text_origin); ok {
		if widget.visible || .Focused in widget.state {
			// Draw body
			draw_rounded_box_fill(widget.box, core.style.rounding, core.style.color.background)
			draw_rounded_box_stroke(
				widget.box,
				core.style.rounding,
				1 + widget.focus_time,
				interpolate_colors(
					widget.focus_time,
					core.style.color.substance,
					core.style.color.accent,
				),
			)
			// Draw text placeholder
			if len(text_info.text) == 0 {
				text_info := text_info
				text_info.text = info.placeholder
				draw_text(text_origin, text_info, core.style.color.substance)
			}
			// First draw the highlighting behind the text
			if .Focused in widget.last_state {
				draw_text_highlight(text_job, text_origin, fade(core.style.color.accent, 0.5))
			}
			// Then draw the text
			draw_text_glyphs(text_job, text_origin, core.style.color.content)
			// Draw the cursor in front of the text
			if .Focused in widget.last_state {
				draw_text_cursor(text_job, text_origin, core.style.color.accent)
			}
			// Draw decal
			if variant.icon_time > 0 {
				a := box_height(widget.box) / 2
				center := [2]f32{widget.box.hi.x, widget.box.lo.y} + [2]f32{-a, a}
				switch info.decal {
				case .None:
					break
				case .Check:
					scale := [2]f32{1 + 4 * variant.icon_time, 5}
					begin_path()
					point(center + {-1, -0.047} * scale)
					point(center + {-0.333, 0.619} * scale)
					point(center + {1, -0.713} * scale)
					stroke_path(2, {0, 255, 120, 255})
					end_path()
				case .Loader:
					draw_loader(center, 5, core.style.color.content)
				}
			}
			// Draw disabled overlay
			if widget.disable_time > 0 {
				draw_rounded_box_fill(
					widget.box,
					core.style.rounding,
					fade(core.style.color.background, widget.disable_time * 0.5),
				)
			}
		}

		// Mouse selection
		last_selection := e.selection
		if .Pressed in widget.state && text_job.hovered_rune != -1 {
			if .Pressed not_in widget.last_state {
				// Set click anchor
				variant.anchor = text_job.hovered_rune
				// Initial selection
				if widget.click_count == 3 {
					text_editor_execute(e, .Select_All)
				} else {
					e.selection = {text_job.hovered_rune, text_job.hovered_rune}
				}
			}
			switch widget.click_count {

			case 2:
				if text_job.hovered_rune < variant.anchor {
					if text_info.text[text_job.hovered_rune] == ' ' {
						e.selection[0] = text_job.hovered_rune
					} else {
						e.selection[0] = max(
							0,
							strings.last_index_any(text_info.text[:text_job.hovered_rune], " \n") +
							1,
						)
					}
					e.selection[1] = strings.index_any(text_info.text[variant.anchor:], " \n")
					if e.selection[1] == -1 {
						e.selection[1] = len(text_info.text)
					} else {
						e.selection[1] += variant.anchor
					}
				} else {
					e.selection[1] = max(
						0,
						strings.last_index_any(text_info.text[:variant.anchor], " \n") + 1,
					)
					if (text_job.hovered_rune > 0 &&
						   text_info.text[text_job.hovered_rune - 1] == ' ') {
						e.selection[0] = 0
					} else {
						e.selection[0] = strings.index_any(
							text_info.text[text_job.hovered_rune:],
							" \n",
						)
					}
					if e.selection[0] == -1 {
						e.selection[0] = len(text_info.text) - text_job.hovered_rune
					}
					e.selection[0] += text_job.hovered_rune
				}

			case 1:
				e.selection[0] = text_job.hovered_rune
			}
		}
		if last_selection != e.selection {
			core.draw_next_frame = true
		}
	}

	end_widget()
	return
}

do_text_input :: proc(info: Text_Input_Info, loc := #caller_location) -> Text_Input_Result {
	return add_text_input(make_text_input(info, loc))
}
