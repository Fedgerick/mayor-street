class_name ServiceDefs
extends RefCounted
## Service numbers for the city's service buildings, keyed by catalog id. Name, size, cost,
## upkeep, unlock tier and tags live in Catalog (scripts/catalog.gd); only what services/
## computes with lives here.
##
##   service: power / park / garbage / police / fire
##   mw: a plant's output.  radius: tiles of coverage.  strength: coverage at the centre (1 = full).
##   tons: garbage collected per day.

const DEFS := {
	"coal_plant": {"service": "power", "mw": 80.0},
	"gas_plant": {"service": "power", "mw": 160.0},
	"solar_farm": {"service": "power", "mw": 60.0},
	"wind_turbine": {"service": "power", "mw": 10.0},

	"small_park": {"service": "park", "radius": 4.0, "strength": 0.6},
	"plaza": {"service": "park", "radius": 5.0, "strength": 0.7},
	"sports_field": {"service": "park", "radius": 7.0, "strength": 0.8},
	"city_park": {"service": "park", "radius": 11.0, "strength": 1.0},
	"stadium": {"service": "park", "radius": 8.0, "strength": 0.5},

	"garbage_depot": {"service": "garbage", "radius": 16.0, "tons": 60.0},
	"recycling_center": {"service": "garbage", "radius": 20.0, "tons": 100.0},
	"landfill": {"service": "garbage", "radius": 12.0, "tons": 45.0},

	"police_station": {"service": "police", "radius": 13.0, "strength": 1.0},
	"police_hq": {"service": "police", "radius": 22.0, "strength": 1.4},

	"fire_station": {"service": "fire", "radius": 14.0, "strength": 1.0},
}

## Power demand in MW per resident / job, by City.Zone.
const MW_PER_CAP := [0.0, 0.004, 0.006, 0.01]
## Garbage in tons per day per resident / job, by City.Zone.
const TONS_PER_CAP := [0.0, 0.002, 0.003, 0.005]
## Every other catalog building (services, specials) draws this much power (MW) per tile of
## footprint and makes this much garbage (tons / day) per tile.
const SPECIAL_MW := 0.4
const SPECIAL_TONS := 0.2
const POWER_LINE_UPKEEP := 0.05


static func has(kind: String) -> bool:
	return DEFS.has(kind)


static func get_def(kind: String) -> Dictionary:
	return DEFS.get(kind, {})


static func service_of(kind: String) -> String:
	return DEFS.get(kind, {}).get("service", "")
