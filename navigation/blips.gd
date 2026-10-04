class_name Blips
extends RefCounted
## The little map symbols shared by the minimap and the city map. Each blip is a Dictionary:
##   pos    Vector3 world position
##   kind   "home", "phone", "job", "waypoint", "cop", "place", "car", "enemy", "pickup"
##   color  Color
##   label  String (the city map shows it on hover and in the legend)
##   edge   bool: pinned to the minimap's rim when it is out of range (targets do this)

const HOME := Color(0.35, 0.85, 0.45)
const PHONE := Color(0.3, 0.75, 0.95)
const WAYPOINT := Color(0.85, 0.35, 0.95)
const JOB := Color(1.0, 0.85, 0.2)
const COP_BLUE := Color(0.3, 0.5, 1.0)
const COP_RED := Color(1.0, 0.25, 0.25)
const YOU := Color(1, 1, 1)
const OUTLINE := Color(0.03, 0.04, 0.06, 0.9)

## Legend rows for the city map: kind, color, text.
const LEGEND := [
	["you", YOU, "You"],
	["home", HOME, "Home"],
	["job", JOB, "Job or target"],
	["waypoint", WAYPOINT, "Waypoint"],
	["phone", PHONE, "Payphone"],
	["cop", COP_BLUE, "Police"],
	["place", Catalog.RED, "Special building"],
]


## Draws one symbol centred on p, about 2 * r pixels across.
static func draw(ci: CanvasItem, kind: String, p: Vector2, col: Color, r: float, heading := 0.0) -> void:
	match kind:
		"you":
			var f := Vector2(sin(heading), -cos(heading))
			var side := Vector2(-f.y, f.x)
			var pts := PackedVector2Array([p + f * r * 1.25, p - f * r * 0.8 + side * r * 0.9,
				p - f * r * 0.35, p - f * r * 0.8 - side * r * 0.9])
			var big := PackedVector2Array()
			for q in pts:
				big.append(p + (q - p) * 1.35)
			ci.draw_colored_polygon(big, OUTLINE)
			ci.draw_colored_polygon(pts, col)
		"home":
			var body := Rect2(p + Vector2(-r * 0.7, -r * 0.15), Vector2(r * 1.4, r * 0.95))
			var roof := PackedVector2Array([p + Vector2(-r * 1.0, -r * 0.1), p + Vector2(0, -r * 1.05), p + Vector2(r * 1.0, -r * 0.1)])
			ci.draw_circle(p, r * 1.35, OUTLINE)
			ci.draw_rect(body, col)
			ci.draw_colored_polygon(roof, col)
			ci.draw_rect(Rect2(p + Vector2(-r * 0.18, r * 0.3), Vector2(r * 0.36, r * 0.5)), OUTLINE)
		"phone":
			ci.draw_circle(p, r * 1.05, OUTLINE)
			ci.draw_circle(p, r * 0.8, col)
			ci.draw_rect(Rect2(p + Vector2(-r * 0.22, -r * 0.45), Vector2(r * 0.44, r * 0.9)), Color(1, 1, 1, 0.95))
		"waypoint":
			var d := PackedVector2Array([p + Vector2(0, -r * 1.2), p + Vector2(r * 0.9, 0), p + Vector2(0, r * 1.2), p + Vector2(-r * 0.9, 0)])
			var o := PackedVector2Array()
			for q in d:
				o.append(p + (q - p) * 1.3)
			ci.draw_colored_polygon(o, OUTLINE)
			ci.draw_colored_polygon(d, col)
		"cop":
			ci.draw_circle(p, r * 0.75, OUTLINE)
			ci.draw_circle(p, r * 0.55, col)
		"place":
			ci.draw_rect(Rect2(p - Vector2(r, r) * 0.8, Vector2(r, r) * 1.6), OUTLINE)
			ci.draw_rect(Rect2(p - Vector2(r, r) * 0.55, Vector2(r, r) * 1.1), col)
		"car", "pickup", "enemy":
			ci.draw_circle(p, r * 0.85, OUTLINE)
			ci.draw_circle(p, r * 0.62, col)
		_:  # "job" and anything else: a ringed target
			ci.draw_circle(p, r * 1.2, OUTLINE)
			ci.draw_circle(p, r * 0.95, col)
			ci.draw_circle(p, r * 0.45, OUTLINE)
			ci.draw_circle(p, r * 0.28, col)
