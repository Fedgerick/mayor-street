class_name ShopStock
extends RefCounted
## What Harbor Arms & Supply sells (catalog "gun_shop", unlocked at 2,500 people).
##
## kind:
##   weapon  the gun with a full first load (StreetCombat.give)
##   ammo    `rounds` more for `weapon` (buying ammo for a gun you don't carry gives you it)
##   armor   a full vest
##   medkit  carried, up to MAX_MEDKITS; H uses one (+50 health)
##   home    shows up in your home, bought once; some do something (see `does`)
##   quest   bought once; sets Progress flag `flag`, which starts a quest
##   count   adds `n` to a Progress count `count` (lock picks: StreetMode spends them)

const MAX_MEDKITS := 5
const MEDKIT_HEAL := 50.0
const DISCOUNT := 0.8      # with the "shop_discount" flag (the Open for Business quest)

const ITEMS := [
	{"id": "pistol", "name": "Pistol", "price": 300, "kind": "weapon", "weapon": &"pistol",
		"desc": "A 9 mm with a full magazine and two spares."},
	{"id": "shotgun", "name": "Pump shotgun", "price": 750, "kind": "weapon", "weapon": &"shotgun",
		"desc": "Eight pellets a shot. Clears a doorway."},
	{"id": "pistol_ammo", "name": "Pistol ammo (34)", "price": 40, "kind": "ammo", "weapon": &"pistol", "rounds": 34,
		"desc": "Two boxes of 9 mm."},
	{"id": "shotgun_ammo", "name": "Shotgun shells (12)", "price": 60, "kind": "ammo", "weapon": &"shotgun", "rounds": 12,
		"desc": "A box of buckshot."},
	{"id": "armor", "name": "Body armor", "price": 250, "kind": "armor",
		"desc": "A full vest. Soaks up bullets before your health does."},
	{"id": "med_kit", "name": "Med kit", "price": 90, "kind": "medkit",
		"desc": "Carry up to 5. Press H to patch yourself up (+50 health)."},
	{"id": "lock_picks", "name": "Lock picks (3)", "price": 200, "kind": "count", "count": "lock_picks", "n": 3,
		"desc": "Open a parked car quietly: no theft, no stars. One pick a car."},
	{"id": "harbor_map", "name": "Old harbor map", "price": 350, "kind": "quest", "flag": "item:harbor_map",
		"desc": "Stained, hand-drawn, three marks near the docks. The clerk swears it's real."},
	{"id": "home_safe", "name": "Home safe", "price": 2500, "kind": "home", "does": "safe",
		"desc": "For your home. Hospital bills and bail cost you half."},
	{"id": "weapon_locker", "name": "Weapon locker", "price": 1500, "kind": "home", "does": "locker",
		"desc": "For your home. The police can't take your guns when you're Busted."},
	{"id": "med_cabinet", "name": "First aid cabinet", "price": 800, "kind": "home", "does": "heal",
		"desc": "For your home. Press E at it for full health, any time you're in."},
	{"id": "big_tv", "name": "Big-screen TV", "price": 1200, "kind": "home",
		"desc": "Sixty-five inches on the TV stand. The neighbours will hear the game."},
	{"id": "arcade", "name": "Arcade cabinet", "price": 900, "kind": "home",
		"desc": "A glowing classic for the corner by the door."},
	{"id": "fish_tank", "name": "Fish tank", "price": 650, "kind": "home",
		"desc": "A lit aquarium under the window."},
	{"id": "floor_lamp", "name": "Floor lamp", "price": 150, "kind": "home",
		"desc": "Warm light by the couch."},
	{"id": "palm", "name": "Potted palm", "price": 120, "kind": "home",
		"desc": "A little green by the wardrobe."},
	{"id": "trophy", "name": "Gold trophy", "price": 2000, "kind": "home",
		"desc": "Says WORLD'S BEST on it. Nobody asks what at."},
]


static func get_item(id: String) -> Dictionary:
	for it in ITEMS:
		if it.id == id:
			return it
	return {}


static func price(it: Dictionary, discount: bool) -> int:
	return int(round(float(it.price) * (DISCOUNT if discount else 1.0)))
