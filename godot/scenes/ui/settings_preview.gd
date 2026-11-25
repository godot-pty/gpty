class_name SettingsPreview
extends VBoxContainer
## The Settings card's one live sample: a scratch pane mock that plays the
## selected transition through `PaneTransitions` and the selected ambient effect
## through `PaneEffects`, with a sidebar strip when the effect scope includes it.
##
## The sample is never a pane body. The transition runner and the effect host
## are the shipped implementations, so "Pop" here is the Pop a pane spawn will
## play, and "Film grain" is the shader a pane's ground will paint. The preview
## is hidden and paused on every section but Appearance, and below the card
## width that cannot hold its column.

const STAGE_HEIGHT := 170.0
const SIDEBAR_STRIP_WIDTH := 40.0
## Room inside the stage for a slide entry to enter from; without it the
## runner clamps the offset to zero and a Slide preview would be a fade.
const SLIDE_ROOM := 12.0
const GAP := 6.0

var _caption: Label = null
var _stage: Control = null
var _sample_a: SettingsSample = null
var _sample_b: SettingsSample = null
var _strip: Control = null
var _strip_ground: ColorRect = null
var _strip_effect: EffectSurface = null
var _strip_bars: Array[ColorRect] = []
var _transitions := PaneTransitions.new()
var _finish_timer: Timer = null
var _finish_action := ""
var _mode := ""
var _available := true
var _swap_layout := false
var _swap_playing := false
var _sample_ground := Color.BLACK
var _sample_font_px := 12

func _ready() -> void:
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_theme_constant_override("separation", UiTokens.SPACE_SM)

	var title := Label.new()
	title.name = "PreviewTitle"
	title.text = "Preview"
	title.add_theme_font_size_override("font_size", UiTokens.FS_HEADING)
	add_child(title)

	_stage = Control.new()
	_stage.name = "Stage"
	_stage.custom_minimum_size.y = STAGE_HEIGHT
	_stage.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_stage.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_stage)

	_ensure_samples()
	_ensure_strip()

	_caption = Label.new()
	_caption.name = "Caption"
	_caption.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_caption.theme_type_variation = UiTheme.MUTED_LABEL
	add_child(_caption)

	_finish_timer = Timer.new()
	_finish_timer.name = "FinishTimer"
	_finish_timer.one_shot = true
	_finish_timer.timeout.connect(_on_finish)
	add_child(_finish_timer)

	_stage.resized.connect(_layout_stage)
	refresh()

# ── Public surface ─────────────────────────────────────────────────────

## Re-read the scheme, font, effect and scope. Called when the panel opens, on
## an appearance switch and on any settings save while Appearance is up.
func refresh() -> void:
	_ensure_samples()
	_ensure_strip()
	_style_samples()
	_style_strip()
	_layout_stage()
	if _mode == "":
		_set_caption("Preview sample: the active scheme")

## Play the selected transition for `kind` ("create", "close" or "swap").
func play_motion(kind: String) -> void:
	if not PaneTransitions.KINDS.has(kind):
		return
	_transitions.finish_all()
	_finish_timer.stop()
	_swap_playing = false
	_swap_layout = kind == "swap"
	_mode = "motion"
	_ensure_samples()
	_style_samples()
	_apply_visibility()

	var id := PaneTransitions.choice(kind)
	var values := PaneTransitions.param_values(kind, id)
	var duration_ms := int(values.get("duration_ms", 0.0))
	var caption := "%s · %s · %d ms" % [kind.capitalize(),
		PaneTransitions.animation_label(id), duration_ms]
	if not UiMotion.enabled():
		caption += " · motion Off"
	_set_caption(caption)

	if not _available or not is_visible_in_tree():
		# No tween can start on a hidden sample; draw the final frame and keep
		# the caption so the picker still names what it selected.
		_rebuild_samples()
		return

	_layout_stage()
	if _swap_layout:
		var before := {
			_sample_a: Rect2(_sample_a.position, _sample_a.size),
			_sample_b: Rect2(_sample_b.position, _sample_b.size),
		}
		var a_pos := _sample_a.position
		var b_pos := _sample_b.position
		_sample_a.position = b_pos
		_sample_b.position = a_pos
		_swap_playing = true
		if _transitions.swap(before, true):
			_arm_finish(duration_ms, "restore")
		else:
			_restore_swap()
	elif kind == "close":
		if _transitions.close(_sample_a, true, "left"):
			_arm_finish(duration_ms, "rebuild")
		else:
			_rebuild_samples.call_deferred()
	else:
		_transitions.create(_sample_a, true, "left")

## Show the selected ambient effect at the selected intensity and scope.
func play_effect() -> void:
	_mode = "effect"
	refresh()
	var id := UiEffects.ambient_id()
	var level := UiEffects.level()
	var entry: Dictionary = UiEffects.AMBIENT.get(id, {})
	var rate := "static, redrawn on change"
	if bool(entry.get("animated", false)):
		rate = "animated at %d Hz" % int(entry["hz"])
		if not UiMotion.enabled():
			rate += " · frozen by Motion Off"
	var scope: String = str(UiEffects.SCOPE_LABELS[UiEffects.scope()])
	var caption := "Effect: %s · %s · %s · %s" % [UiEffects.ambient_label(id),
		UiEffects.LABELS[level], rate, scope]
	if level == UiEffects.OFF:
		caption = "Effect: %s · Off · no effect drawn · %s" % [
			UiEffects.ambient_label(id), scope]
	_set_caption(caption)
	_layout_stage()

## Play one reactive cue on the sample under the shipped 334 ms gate. Returns
## whether it started (a hidden preview or a trigger inside the window is
## refused, exactly as a concept fire is).
func play_cue(effect_id: String) -> bool:
	_ensure_samples()
	return _sample_a.cue_layer().flash(effect_id)

## Stop everything and leave a final frame: the preview column is hidden, or
## the card is closing.
func pause() -> void:
	_transitions.finish_all()
	_finish_timer.stop()
	_swap_playing = false
	_swap_layout = false
	_ensure_samples()
	_layout_stage()
	for sample in _samples():
		if is_instance_valid(sample) and is_instance_valid(sample.effect_surface()):
			sample.effect_surface().pin(true)
	if is_instance_valid(_strip_effect):
		_strip_effect.pin(true)

func set_available(available: bool) -> void:
	_available = available

## Freeze a playing transition at `progress` (0-1) for a capture. The finish
## timer is stopped so the frame survives the harness's settle.
func pin_motion(progress: float) -> void:
	_finish_timer.stop()
	_transitions.pin(progress)

## Freeze the ambient clock at phase 0 for a capture. `cue` additionally pins
## that cue's final frame (a tint wash or a pulse border; particles have no
## still frame).
func pin_effect(cue := "") -> void:
	_ensure_samples()
	for sample in _samples():
		if is_instance_valid(sample) and is_instance_valid(sample.effect_surface()):
			sample.effect_surface().pin(true)
	if is_instance_valid(_strip_effect):
		_strip_effect.pin(true)
	if cue != "":
		_sample_a.cue_layer().pin_cue(cue)

func caption_text() -> String:
	return _caption.text if _caption != null else ""

# ── Build and layout ──────────────────────────────────────────────────

func _ensure_samples() -> void:
	if _sample_a == null or not is_instance_valid(_sample_a):
		_sample_a = SettingsSample.new()
		_sample_a.name = "SampleA"
		_stage.add_child(_sample_a)
	if _sample_b == null or not is_instance_valid(_sample_b):
		_sample_b = SettingsSample.new()
		_sample_b.name = "SampleB"
		_sample_b.visible = false
		_stage.add_child(_sample_b)

func _ensure_strip() -> void:
	if _strip != null and is_instance_valid(_strip):
		return
	_strip = Control.new()
	_strip.name = "SidebarStrip"
	_strip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_stage.add_child(_strip)
	_strip_ground = ColorRect.new()
	_strip_ground.name = "StripGround"
	_strip_ground.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_strip.add_child(_strip_ground)
	_strip_effect = EffectSurface.new()
	_strip_effect.name = "SidebarStripEffect"
	_strip_effect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_strip.add_child(_strip_effect)
	for i in 3:
		var bar := ColorRect.new()
		bar.name = "Bar%d" % (i + 1)
		bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_strip.add_child(bar)
		_strip_bars.append(bar)

func _samples() -> Array:
	var out := []
	if _sample_a != null:
		out.append(_sample_a)
	if _sample_b != null:
		out.append(_sample_b)
	return out

func _style_samples() -> void:
	var scheme := SchemeLibrary.loaded(SettingsManager.active_scheme_path())
	_sample_ground = SchemeLibrary.color(scheme, "background", Color.BLACK)
	var font := TerminalFonts.load_for(SettingsManager.cfg_font_path,
		"res://fonts/DejaVuSansMono.ttf")
	_sample_font_px = clampi(SettingsManager.cfg_font_size, 10, 13)
	var effect_id := UiEffects.pane_ambient_id()
	var level := UiEffects.level()
	for sample in _samples():
		if not is_instance_valid(sample):
			continue
		sample.set_style(scheme, font, _sample_font_px)
		var effect: EffectSurface = sample.effect_surface()
		if effect == null:
			continue
		effect.pin(false)
		effect.set_ground(_sample_ground)
		effect.set_cell_height(float(_sample_font_px) * 6.0)
		effect.configure(effect_id, level)

func _style_strip() -> void:
	if _strip == null or not is_instance_valid(_strip):
		return
	var in_scope := UiEffects.sidebar_in_scope()
	_strip.visible = in_scope
	_strip_ground.color = SettingsManager.cfg_sidebar_bg
	var pal := UiPalette.active()
	for bar in _strip_bars:
		bar.color = pal.TEXT_MUTED
	if _strip_effect == null or not is_instance_valid(_strip_effect):
		return
	_strip_effect.pin(false)
	_strip_effect.set_ground(SettingsManager.cfg_sidebar_bg)
	_strip_effect.set_cell_height(UiTokens.FS_SMALL * 2.0)
	_strip_effect.configure(UiEffects.ambient_id() if in_scope else "", UiEffects.level())

func _layout_stage() -> void:
	if _stage == null or _swap_playing:
		return
	var w := _stage.size.x
	var h := _stage.size.y
	if w < 4.0 or h < 4.0:
		return
	var inset := SLIDE_ROOM
	var strip_w := SIDEBAR_STRIP_WIDTH if (_strip != null and _strip.visible) else 0.0
	var gap := GAP if strip_w > 0.0 else 0.0
	var sample_w := maxf(1.0, w - inset * 2.0 - strip_w - gap)
	var sample_h := maxf(1.0, h - inset * 2.0)
	if _swap_layout:
		var half := maxf(1.0, (sample_h - GAP) * 0.5)
		_sample_a.position = Vector2(inset, inset)
		_sample_a.size = Vector2(sample_w, half)
		_sample_b.position = Vector2(inset, inset + half + GAP)
		_sample_b.size = Vector2(sample_w, half)
		_sample_b.visible = true
	else:
		_sample_a.position = Vector2(inset, inset)
		_sample_a.size = Vector2(sample_w, sample_h)
		_sample_b.visible = false
	if _strip != null and _strip.visible:
		_strip.position = Vector2(w - inset - strip_w, inset)
		_strip.size = Vector2(strip_w, sample_h)
		_strip_ground.position = Vector2.ZERO
		_strip_ground.size = _strip.size
		for i in _strip_bars.size():
			var bar: ColorRect = _strip_bars[i]
			bar.position = Vector2(8.0, 10.0 + i * 12.0)
			bar.size = Vector2(strip_w - 16.0, 2.0)

func _arm_finish(duration_ms: int, action: String) -> void:
	_finish_action = action
	_finish_timer.start(maxf(float(duration_ms) / 1000.0 + 0.05, 0.05))

func _on_finish() -> void:
	if _finish_action == "restore":
		_restore_swap()
	elif _finish_action == "rebuild":
		_rebuild_samples()

func _restore_swap() -> void:
	_swap_playing = false
	_swap_layout = false
	_layout_stage()

func _rebuild_samples() -> void:
	_finish_timer.stop()
	_swap_playing = false
	for sample in _samples():
		if is_instance_valid(sample):
			_stage.remove_child(sample)
			sample.free()
	_sample_a = null
	_sample_b = null
	_ensure_samples()
	_style_samples()
	_layout_stage()

func _apply_visibility() -> void:
	# The strip's own visibility is `_style_strip`'s; this keeps the sample's
	# rect in step when the scope changed while a transition was playing.
	_layout_stage()

func _set_caption(text: String) -> void:
	if _caption != null:
		_caption.text = text
	var name_text := text
	for sample in _samples():
		if is_instance_valid(sample):
			sample.accessibility_name = name_text
			sample.tooltip_text = name_text
