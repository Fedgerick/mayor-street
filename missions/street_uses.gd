class_name StreetUses
extends RefCounted
## What a building opens up on the street: the jobs whose templates need one of its tags.
## The build menu shows it when you hover a building, and Missions announces it when one is
## placed, so the Mayor can see that the bank and the hideout make a heist, and that the
## farther apart they are, the more it pays.
##
##     StreetUses.jobs(["bank", "robbable"], "Second National Bank")
##         -> [{title, side, contact, quest, partner}]   partner: the other end of the route
##     StreetUses.text(tags, name)  -> one line for the build menu ("" when nothing uses it)

## Every ordinary building has these, so they say nothing about a special one.
const GENERIC := ["home", "shop", "industrial"]
## How a slot reads when it's some other building.
const NOUN := {"hideout": "your hideout", "chop_shop": "a chop shop", "police": "a police station",
	"police_hq": "Police HQ", "home": "a home", "shop": "a shop", "industrial": "a factory",
	"warehouse": "a warehouse", "bank": "the bank", "hospital": "the hospital", "nightclub": "a nightclub",
	"pawn_shop": "a pawn shop", "fire_station": "a fire station", "casino": "the casino", "park": "a park",
	"airfield": "the airfield", "stadium": "the stadium", "radio_tower": "the radio tower",
	"mansion": "the mansion", "vault": "the Federal Reserve", "power_plant": "a power plant",
	"garbage_depot": "the garbage depot", "substation": "a substation", "crime_den": "a crime den"}

static var _templates: Array = []


static func templates() -> Array:
	if _templates.is_empty():
		var data = JSON.parse_string(FileAccess.get_file_as_string(MissionDirector.TEMPLATES_PATH))
		if data:
			_templates = data.templates
	return _templates


static func jobs(tags: Array, name: String) -> Array:
	var out := []
	for t in templates():
		if t.has("special"):
			continue  # spawned specials hand these out, not placed buildings
		var mine := ""
		for slot in t.slots:
			var tag: String = t.slots[slot].tag
			if tag in tags and not tag in GENERIC:
				mine = slot
				break
		if mine == "":
			continue
		var title: String = t.title
		var partner := ""
		for slot in t.slots:
			var tag: String = t.slots[slot].tag
			var word: String = name if slot == mine else NOUN.get(tag, tag.replace("_", " "))
			title = title.replace("{%s}" % slot, word)
			# Pay grows with the road distance to a building the Mayor places too.
			var route: Array = t.get("route", [])
			if slot != mine and slot in route and mine in route and not tag in GENERIC:
				partner = NOUN.get(tag, tag)
		title = title.replace("{car}", "car").replace("{district}", "downtown")
		title = title.replace("The the ", "The ").replace(" the the ", " the ")
		out.append({"title": title, "side": t.side, "contact": Contacts.of_template(t),
			"quest": t.get("quest_only", false) or t.has("after"), "partner": partner})
	return out


static func text(tags: Array, name: String) -> String:
	var list := jobs(tags, name)
	if list.is_empty():
		return ""
	var parts: PackedStringArray = []
	for j in list.slice(0, 4):
		var bits: PackedStringArray = ["good" if j.side == "good" else "bad"]
		if j.quest:
			bits.append("story")
		if j.partner != "":
			bits.append("pays more the farther it is from " + j.partner)
		parts.append("%s (%s)" % [j.title, ", ".join(bits)])
	var more := "" if list.size() <= 4 else "  and %d more" % (list.size() - 4)
	return "On the street: " + "  ·  ".join(parts) + more
