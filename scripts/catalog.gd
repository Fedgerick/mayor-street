class_name Catalog
extends RefCounted
## Every building the Mayor can buy (service buildings and specials) plus the milestone
## tiers that unlock them. Data and lookups only; see scripts/PROGRESS_INTERFACE.md.
##
## Models and door spots come from the art thread's art/specials.json. Service numbers
## (MW, radius, tons) stay in services/service_defs.gd under the same ids.

const GROUPS := ["power", "parks", "garbage", "safety", "business", "street", "landmarks"]
const GROUP_NAMES := {
	"power": "Power", "parks": "Parks", "garbage": "Garbage", "safety": "Safety",
	"business": "Business", "street": "Street", "landmarks": "Landmarks",
}

## Milestone tiers. Goals: "pop" = population at least this; "income" = income per resident
## ($ a year) at least this. "any": either goal is enough, otherwise every goal must be met.
const TIERS := [
	{"name": "Town", "goals": {}},
	{"name": "Village", "goals": {"pop": 1000}},
	{"name": "Small city", "goals": {"pop": 5000}},
	{"name": "City", "goals": {"pop": 15000, "income": 52000}, "any": true},
	{"name": "Big city", "goals": {"pop": 40000, "income": 48000}},
	{"name": "Metropolis", "goals": {"pop": 70000, "income": 58000}},
]

const ART_MANIFEST := "res://art/specials.json"
const MODEL_DIR := "res://assets/kit/specials/"

## Every field an entry leaves out.
const DEFAULTS := {
	"group": "business", "size": 1, "cost": 1000, "upkeep": 0, "tier": 0, "tags": [],
	"unique": false, "needs_road": true, "placement": "lot", "menu": true, "interior": "",
	"unlock_hint": "", "desc": "",
	# Unlocked once the city has this many people, apart from the milestone tiers (tier -1).
	"unlock_pop": 0,
	# Look: the sign and trim colour, plus a stand-in while the model is missing (a kit
	# building of the same size, or a plain block of this colour and height).
	"accent": Color(0.85, 0.22, 0.2), "stand_in": "c_2", "color": Color(0.75, 0.74, 0.72), "height": 10.0,
}

const ORANGE := Color(0.95, 0.55, 0.12)
const GREEN := Color(0.25, 0.6, 0.3)
const BLUE := Color(0.18, 0.3, 0.6)
const RED := Color(0.85, 0.22, 0.2)
const GOLD := Color(0.95, 0.8, 0.2)
const TEAL := Color(0.1, 0.6, 0.62)
const BROWN := Color(0.55, 0.35, 0.22)
const BANK_GREEN := Color(0.1, 0.45, 0.35)
const PURPLE := Color(0.55, 0.3, 0.65)

## In build menu order. upkeep is $ a day (negative earns money); cost is city funds.
const DEFS := {
	# ---------------------------------------------------------------- power ---
	"coal_plant": {"name": "Coal Power Plant", "group": "power", "size": 2, "cost": 6000, "upkeep": 60,
		"tags": ["power_plant", "industrial"], "needs_road": false, "accent": ORANGE,
		"desc": "Cheap, dirty power for a young town."},
	"power_line": {"name": "Power Line", "group": "power", "size": 1, "cost": 5, "upkeep": 0,
		"tags": ["power_line"], "placement": "line", "needs_road": false,
		"desc": "Carries power across land without roads. Drag like a road."},
	"gas_plant": {"name": "Gas Power Plant", "group": "power", "size": 1, "cost": 12000, "upkeep": 90, "tier": 3,
		"tags": ["power_plant", "industrial"], "needs_road": false, "accent": TEAL,
		"desc": "Twice the power of coal, far less smoke."},
	"solar_farm": {"name": "Solar Farm", "group": "power", "size": 2, "cost": 16000, "upkeep": 30, "tier": 4,
		"tags": ["power_plant", "green"], "needs_road": false, "accent": BLUE,
		"desc": "Clean power by day. Lifts nearby land value."},
	"wind_turbine": {"name": "Wind Turbine", "group": "power", "size": 1, "cost": 2500, "upkeep": 8, "tier": 4,
		"tags": ["power_plant", "green"], "needs_road": false, "accent": Color(0.9, 0.9, 0.92),
		"desc": "A little clean power. Best along the coast."},
	# ---------------------------------------------------------------- parks ---
	"small_park": {"name": "Small Park", "group": "parks", "size": 1, "cost": 300, "upkeep": 3,
		"tags": ["park", "meeting_spot"], "needs_road": false, "accent": GREEN,
		"model": "res://assets/kit/civic/park.glb",
		"desc": "Trees and benches. Neighbours are happier and land is worth more."},
	"plaza": {"name": "Civic Plaza", "group": "parks", "size": 1, "cost": 600, "upkeep": 4, "tier": 2,
		"tags": ["park", "plaza", "meeting_spot"], "needs_road": false, "accent": GREEN,
		"desc": "A paved square with a fountain, busy by day."},
	"sports_field": {"name": "Municipal Sports Field", "group": "parks", "size": 2, "cost": 2200, "upkeep": 12,
		"tier": 3, "tags": ["park", "sports", "meeting_spot"], "needs_road": false, "accent": GREEN,
		"desc": "Ball games every weekend. A big lift for happiness."},
	"city_park": {"name": "Central Park", "group": "parks", "size": 2, "cost": 6500, "upkeep": 25, "tier": 4,
		"tags": ["park", "landmark", "meeting_spot"], "unique": true, "needs_road": false, "accent": GREEN,
		"desc": "The city's great lawn. Raises land value far around it."},
	# -------------------------------------------------------------- garbage ---
	"garbage_depot": {"name": "Garbage Depot", "group": "garbage", "size": 1, "cost": 3500, "upkeep": 35,
		"tags": ["garbage_depot", "industrial"], "accent": GREEN,
		"desc": "Trucks collect garbage from the streets around it."},
	"landfill": {"name": "Landfill", "group": "garbage", "size": 2, "cost": 2500, "upkeep": 20,
		"tags": ["garbage_depot", "landfill"], "needs_road": false, "accent": BROWN,
		"desc": "Cheap and smelly. Nobody wants to live next to it."},
	"recycling_center": {"name": "Recycling Center", "group": "garbage", "size": 1, "cost": 8000, "upkeep": 45,
		"tier": 3, "tags": ["garbage_depot", "green"], "accent": GREEN,
		"desc": "Collects more garbage, further out, and cleanly."},
	# --------------------------------------------------------------- safety ---
	"police_station": {"name": "Police Station", "group": "safety", "size": 1, "cost": 4000, "upkeep": 45,
		"tags": ["police"], "interior": "police", "accent": BLUE,
		"desc": "Lowers crime nearby. Cops come from here."},
	"fire_station": {"name": "Fire Station", "group": "safety", "size": 1, "cost": 3500, "upkeep": 40,
		"tags": ["fire_station", "emergency"], "accent": RED,
		"desc": "Lowers the risk of fire nearby. Fire trucks come from here."},
	"police_hq": {"name": "Police Headquarters", "group": "safety", "size": 2, "cost": 14000, "upkeep": 110,
		"tier": 3, "tags": ["police", "police_hq"], "unique": true, "interior": "police", "accent": BLUE,
		"desc": "Covers a wide area. Banks near it are harder to rob."},
	"hospital": {"name": "General Hospital", "group": "safety", "size": 2, "cost": 12000, "upkeep": 80, "tier": 3,
		"tags": ["hospital", "emergency"], "accent": RED,
		"desc": "Ambulances come from here, and you wake up here when Wasted."},
	# ------------------------------------------------------------- business ---
	"gas_station": {"name": "Gas 'n' Go", "group": "business", "size": 1, "cost": 1500, "upkeep": -8, "tier": 1,
		"tags": ["shop", "gas_station", "robbable"], "interior": "shop", "accent": ORANGE,
		"desc": "Fuel and snacks, open all night. Earns the city a little."},
	"pawn_shop": {"name": "Lucky Pawn", "group": "business", "size": 1, "cost": 1800, "upkeep": -8, "tier": 1,
		"tags": ["shop", "pawn_shop", "fence", "robbable"], "interior": "shop", "accent": GOLD,
		"desc": "Buys anything, no questions asked."},
	"diner": {"name": "Starlite Diner", "group": "business", "size": 1, "cost": 1200, "upkeep": -6, "tier": 1,
		"tags": ["shop", "diner", "robbable"], "interior": "shop", "accent": RED,
		"desc": "Coffee, pie and gossip."},
	"clothing_shop": {"name": "Threads Clothing", "group": "business", "size": 1, "cost": 1600, "upkeep": -8, "tier": 1,
		"tags": ["shop", "clothing_shop", "robbable"], "interior": "shop_clothes", "accent": PURPLE,
		"desc": "Hoodies, jackets, hats and boots, and the colours the wardrobe doesn't have."},
	"nightclub": {"name": "Club Voltage", "group": "business", "size": 1, "cost": 6000, "upkeep": -25, "tier": 2,
		"tags": ["nightclub", "nightlife"], "interior": "nightclub", "accent": PURPLE,
		"desc": "Loud music and louder friends. Busy after dark."},
	"chop_shop": {"name": "Eddie's Auto Body", "group": "business", "size": 1, "cost": 4000, "upkeep": -12,
		"tier": 2, "tags": ["chop_shop", "garage"], "accent": ORANGE,
		"desc": "Fixes cars. Takes cars apart too, if you know who to ask."},
	"warehouse": {"name": "Pier 4 Warehouse", "group": "business", "size": 1, "cost": 3000, "upkeep": -10,
		"tier": 2, "tags": ["warehouse", "industrial"], "accent": BROWN, "stand_in": "i_2",
		"desc": "Storage near the docks. What's inside is anyone's guess."},
	"salvage_yard": {"name": "Rusty's Salvage & Tow", "group": "business", "size": 1, "cost": 5000, "upkeep": -15,
		"tier": 1, "tags": ["salvage_yard", "garage", "industrial"], "accent": ORANGE, "stand_in": "i_2",
		"desc": "Two tow trucks clear wrecks off the streets and haul them here. Takes towing jobs."},
	"gun_shop": {"name": "Harbor Arms & Supply", "group": "business", "size": 1, "cost": 7000, "upkeep": -20,
		"tier": -1, "unlock_pop": 2500, "tags": ["shop", "gun_shop", "robbable"], "accent": Color(0.3, 0.32, 0.3),
		"unlock_hint": "Reach 2,500 people",
		"desc": "Guns, ammo, med kits, armor and things for your home. Walk in and press E at the counter."},
	"bank": {"name": "Second National Bank", "group": "business", "size": 1, "cost": 20000, "upkeep": -60,
		"tier": 2, "tags": ["bank", "robbable", "landmark"], "unique": true, "interior": "bank", "accent": BANK_GREEN,
		"desc": "The city's money lives here. The vault fills up in rich districts."},
	"casino": {"name": "The Golden Ace Casino", "group": "business", "size": 2, "cost": 40000, "upkeep": -180,
		"tier": 4, "tags": ["casino", "nightlife", "robbable", "landmark"], "unique": true, "accent": GOLD,
		"desc": "Lights all night and money in the city's pocket."},
	# --------------------------------------------------------------- street ---
	"payphone": {"name": "Payphone", "group": "street", "size": 0, "cost": 150, "upkeep": 1, "tier": 1,
		"tags": ["payphone"], "placement": "street", "needs_road": false, "accent": BLUE,
		"desc": "Goes on a sidewalk. When it rings, someone has a job for you."},
	# ------------------------------------------------------------ landmarks ---
	"bunker": {"name": "The Bunker", "group": "landmarks", "size": 1, "cost": 25000, "upkeep": 30, "tier": 3,
		"tags": ["hideout", "bunker"], "unique": true, "interior": "bunker", "accent": Color(0.4, 0.45, 0.25),
		"desc": "A Cold War shelter under a grassy mound. Sealed. Officially."},
	"stadium": {"name": "City Stadium", "group": "landmarks", "size": 3, "cost": 50000, "upkeep": 120, "tier": 4,
		"tags": ["stadium", "sports", "landmark", "meeting_spot"], "unique": true, "accent": BLUE,
		"desc": "Game nights fill the streets around it."},
	"airfield": {"name": "Municipal Airfield", "group": "landmarks", "size": 3, "cost": 45000, "upkeep": 90,
		"tier": 4, "tags": ["airfield", "escape", "landmark"], "unique": true, "accent": ORANGE,
		"desc": "Small planes, a short runway, and a quick way out of town."},
	"radio_tower": {"name": "KMAY Radio Tower", "group": "landmarks", "size": 1, "cost": 12000, "upkeep": 15,
		"tier": 4, "tags": ["radio_tower", "landmark"], "unique": true, "needs_road": false, "accent": RED,
		"desc": "The city's own station, on the air day and night."},
	"federal_reserve": {"name": "Federal Reserve", "group": "landmarks", "size": 2, "cost": 100000, "upkeep": -250,
		"tier": 5, "tags": ["bank", "vault", "robbable", "landmark"], "unique": true, "interior": "bank",
		"accent": BANK_GREEN, "desc": "The biggest vault in the state."},
	"mansion": {"name": "Mansion on the Hill", "group": "landmarks", "size": 2, "cost": 60000, "upkeep": 40,
		"tier": 5, "tags": ["mansion", "hideout"], "unique": true, "accent": Color(0.55, 0.1, 0.15),
		"unlock_hint": "or Kingpin on the goodness scale",
		"desc": "Gates, a pool and a long view over the city."},
	"landmark_tower": {"name": "Mayor's Tower", "group": "landmarks", "size": 2, "cost": 120000, "upkeep": -150,
		"tier": 5, "tags": ["landmark"], "unique": true, "accent": TEAL,
		"desc": "The tallest thing on the island, with your name on it."},
	# ------------------------------------------------------- spawned only ---
	"substation": {"name": "Substation", "group": "power", "size": 1, "cost": 0, "upkeep": 0, "tier": -1,
		"tags": ["substation"], "menu": false, "needs_road": false, "accent": GOLD,
		"unlock_hint": "Appears on its own when the grid is overloaded",
		"desc": "Part of the power grid."},
}

static var _merged := {}   # id -> full entry (defaults + art manifest), built on first use
static var _art := {}      # id -> art/specials.json entry
static var _art_loaded := false


## The full entry for an id, or {} for an unknown id. Don't modify it.
static func get_def(id: String) -> Dictionary:
	if _merged.has(id):
		return _merged[id]
	if not DEFS.has(id):
		return {}
	var d: Dictionary = DEFAULTS.duplicate(true)
	d.merge(DEFS[id].duplicate(true), true)
	d["id"] = id
	var art := _art_entry(id)
	# The model: set here, else the art manifest's, else the usual place.
	var model := str(d.get("model", ""))
	if model == "" and art.get("model") != null:
		model = str(art.model)
	if model == "":
		model = MODEL_DIR + id + ".glb"
	d["model"] = model if ResourceLoader.exists(model) else ""
	d["door"] = _door(art.get("door"))
	_merged[id] = d
	return d


static func has(id: String) -> bool:
	return DEFS.has(id)


## Ids in build menu order; one group only when given. Spawned-only buildings are left out
## unless all is true.
static func ids(group := "", all := false) -> Array:
	var out := []
	for id in DEFS:
		var d := get_def(id)
		if (group == "" or d.group == group) and (all or d.menu):
			out.append(id)
	return out


static func with_tag(tag: String) -> Array:
	var out := []
	for id in DEFS:
		if tag in get_def(id).tags:
			out.append(id)
	return out


## Ids unlocked by population alone (unlock_pop), with the people each needs.
static func pop_unlocks() -> Dictionary:
	var out := {}
	for id in DEFS:
		var n := int(get_def(id).unlock_pop)
		if n > 0:
			out[id] = n
	return out


## Every id a milestone tier unlocks.
static func ids_for_tier(t: int) -> Array:
	var out := []
	for id in DEFS:
		if int(get_def(id).tier) == t:
			out.append(id)
	return out


static func goal_met(t: int, pop: int, income: float) -> bool:
	if t <= 0:
		return true
	if t >= TIERS.size():
		return false
	var g: Dictionary = TIERS[t].goals
	var met := []
	if g.has("pop"):
		met.append(pop >= int(g.pop))
	if g.has("income"):
		met.append(income >= float(g.income))
	if TIERS[t].get("any", false):
		return met.has(true)
	return not met.has(false)


## "Reach 5,000 people", for a tier's goal.
static func goal_text(t: int) -> String:
	if t <= 0 or t >= TIERS.size():
		return ""
	var g: Dictionary = TIERS[t].goals
	var parts: Array[String] = []
	if g.has("pop"):
		parts.append("%s people" % thousands(int(g.pop)))
	if g.has("income"):
		parts.append("$%s income per resident" % thousands(int(g.income)))
	return "Reach " + (" or " if TIERS[t].get("any", false) else " and ").join(parts)


## What a locked build menu entry shows.
static func lock_text(id: String) -> String:
	var d := get_def(id)
	if d.is_empty():
		return ""
	var t := int(d.tier)
	if t < 0:
		return d.unlock_hint if d.unlock_hint != "" else "Unlocked by a quest"
	var s := goal_text(t)
	return s + (" " + d.unlock_hint if d.unlock_hint != "" else "")


static func thousands(n: int) -> String:
	var s := str(absi(n))
	var out := ""
	while s.length() > 3:
		out = "," + s.substr(s.length() - 3) + out
		s = s.substr(0, s.length() - 3)
	return ("-" if n < 0 else "") + s + out


static func _art_entry(id: String) -> Dictionary:
	if not _art_loaded:
		_art_loaded = true
		if FileAccess.file_exists(ART_MANIFEST):
			var data = JSON.parse_string(FileAccess.get_file_as_string(ART_MANIFEST))
			if data is Dictionary:
				for e in data.get("specials", []):
					if e is Dictionary and e.has("id"):
						_art[str(e.id)] = e
	return _art.get(id, {})


## The door spot in the model's own space (x right, z toward the street), or {}.
static func _door(v: Variant) -> Dictionary:
	if not v is Dictionary:
		return {}
	return {"x": float(v.get("x", 0.0)), "z": float(v.get("z", 0.0)), "yaw_deg": float(v.get("yaw_deg", 0.0))}
