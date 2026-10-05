class_name ClothingStock
extends RefCounted
## What clothing shops sell, and what a look costs to buy: the shop colors
## CharacterLook.CLOTH lists from CLOTH_FREE on, and the clothing styles beyond the free basics.

const ITEMS := {
	"cloth:12": {"name": "Royal purple", "price": 75},
	"cloth:13": {"name": "Sunset orange", "price": 75},
	"cloth:14": {"name": "Bubblegum pink", "price": 75},
	"cloth:15": {"name": "Teal", "price": 75},
	"cloth:16": {"name": "Burgundy", "price": 90},
	"cloth:17": {"name": "Gold", "price": 150},
	"cloth:18": {"name": "Racing green", "price": 90},
	"cloth:19": {"name": "Neon lime", "price": 120},
}
# Clothing styles from the rebuilt characters: "<slot>:<style>".
const STYLE_ITEMS := {
	"top:tank": {"name": "Tank top", "price": 30},
	"top:hoodie": {"name": "Hoodie", "price": 60},
	"top:jacket": {"name": "Jacket", "price": 120},
	"bottom:skirt": {"name": "Skirt", "price": 45},
	"shoes:boots": {"name": "Boots", "price": 80},
	"hat:cap": {"name": "Cap", "price": 35},
	"hat:beanie": {"name": "Beanie", "price": 35},
}


const PERK_DISCOUNT := "perk:shop_discount"   # goodness +25: shops give 15% off
const DISCOUNT := 0.85


static func price(id: String) -> int:
	## What the item costs right now, after the shop discount perk.
	return roundi(list_price(id) * price_factor())


static func list_price(id: String) -> int:
	return int(_item(id).get("price", 0))


static func _item(id: String) -> Dictionary:
	return ITEMS.get(id, STYLE_ITEMS.get(id, {}))


static func price_factor() -> float:
	var tree := Engine.get_main_loop() as SceneTree
	var prog: Node = tree.root.get_node_or_null("Progress") if tree else null
	if prog and prog.call("is_unlocked", PERK_DISCOUNT):
		return DISCOUNT
	return 1.0


static func item_name(id: String) -> String:
	return String(_item(id).get("name", id))


static func cloth_id(i: int) -> String:
	return "cloth:%d" % i


## The shop items a look uses that aren't owned yet: {"ids": [...], "total": dollars}.
## Colors count for the pieces actually worn (no hat, no hat color; a jacket color only
## with a jacket).
static func unpaid(look: CharacterLook, owned: PackedStringArray) -> Dictionary:
	var ids: Array[String] = []
	var wanted: Array[String] = []
	for slot in ["top", "bottom", "shoes", "hat"]:
		var style := look.get_style(slot)
		if style != "":
			wanted.append("%s:%s" % [slot, style])
	var colors := [look.top, look.bottom, look.shoes]
	if look.top_style == "jacket":
		colors.append(look.jacket)
	if look.hat != "":
		colors.append(look.hat_color)
	for c in colors:
		wanted.append(cloth_id(int(c)))
	var total := 0
	for id in wanted:
		if _item(id).is_empty() or owned.has(id) or ids.has(id):
			continue
		ids.append(id)
		total += price(id)
	return {"ids": ids, "total": total}
