class_name ClothingStock
extends RefCounted
## What clothing shops sell, and what a look costs to buy. Today that is the shop colors
## CharacterLook.CLOTH lists from CLOTH_FREE on. The rebuilt characters' new clothes
## (round 3) join here as more items with their own ids.

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
const SLOTS := ["top", "bottom", "shoes"]


const PERK_DISCOUNT := "perk:shop_discount"   # goodness +25: shops give 15% off
const DISCOUNT := 0.85


static func price(id: String) -> int:
	## What the item costs right now, after the shop discount perk.
	return roundi(list_price(id) * price_factor())


static func list_price(id: String) -> int:
	return int(ITEMS.get(id, {}).get("price", 0))


static func price_factor() -> float:
	var tree := Engine.get_main_loop() as SceneTree
	var prog: Node = tree.root.get_node_or_null("Progress") if tree else null
	if prog and prog.call("is_unlocked", PERK_DISCOUNT):
		return DISCOUNT
	return 1.0


static func item_name(id: String) -> String:
	return String(ITEMS.get(id, {}).get("name", id))


static func cloth_id(i: int) -> String:
	return "cloth:%d" % i


## The shop items a look uses that aren't owned yet: {"ids": [...], "total": dollars}.
static func unpaid(look: CharacterLook, owned: PackedStringArray) -> Dictionary:
	var ids: Array[String] = []
	var total := 0
	for slot in SLOTS:
		var id := cloth_id(int(look.get(slot)))
		if ITEMS.has(id) and not owned.has(id) and not ids.has(id):
			ids.append(id)
			total += price(id)
	return {"ids": ids, "total": total}
