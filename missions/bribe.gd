class_name Bribe
extends RefCounted
## Paying off the police: with 1 to 3 wanted stars and a cop close by (an officer on foot
## within 12 m, or a cop car within 16 m), B hands over cash and the stars are gone.
## At 4 or 5 stars nobody takes the money. It costs a little goodness, and a minute must
## pass before the next one. The Ex-cop background (creator/, perk free_bribes_per_day)
## gets that many free bribes per game day.

const PRICE := [0, 250, 600, 1200]   # by star level
const MAX_STARS := 3
const OFFICER_M := 12.0
const CAR_M := 16.0
const COOLDOWN := 60.0
const GOODNESS := -2.0

var cooldown := 0.0
var free_day := -1    # game day the free bribes were last counted for
var free_used := 0


func price(stars: int) -> int:
	return PRICE[stars] if stars > 0 and stars <= MAX_STARS else 0


func free_left(day: int, per_day: int) -> int:
	if day != free_day:
		return per_day
	return maxi(0, per_day - free_used)


func status(stars: int, cop_near: bool, cash: int, day: int, free_per_day: int) -> String:
	## "" when there is nothing to say, "ok" when B works now, else why not.
	if stars <= 0:
		return ""
	if stars > MAX_STARS:
		return "too_hot"
	if not cop_near:
		return ""
	if cooldown > 0.0:
		return "cooldown"
	if free_left(day, free_per_day) > 0:
		return "ok"
	return "ok" if cash >= price(stars) else "broke"


func pay(stars: int, day: int, free_per_day: int) -> int:
	## Records the bribe; returns what it cost (0 when it was a free one).
	cooldown = COOLDOWN
	if free_left(day, free_per_day) > 0:
		if day != free_day:
			free_day = day
			free_used = 0
		free_used += 1
		return 0
	return price(stars)


func tick(delta: float) -> void:
	cooldown = maxf(0.0, cooldown - delta)


static func cop_near(police: Object, at: Vector3) -> bool:
	## Reads citylife/Police: its officers on foot and its cars.
	if police == null:
		return false
	for o in police.officers:
		if Vector2(o.pos.x - at.x, o.pos.z - at.z).length() < OFFICER_M:
			return true
	for c in police.cars:
		if Vector2(c.pos.x - at.x, c.pos.z - at.z).length() < CAR_M:
			return true
	return false


func to_dict() -> Dictionary:
	return {"free_day": free_day, "free_used": free_used}


func from_dict(d: Dictionary) -> void:
	free_day = int(d.get("free_day", -1))
	free_used = int(d.get("free_used", 0))
