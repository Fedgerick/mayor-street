class_name Prof
## Script time by system, for the benchmark report. Systems call lap() between their steps;
## it costs two clock reads, and nothing is kept unless the benchmark switched it on.
##   var t := Prof.now()
##   traffic.step(dt)
##   t = Prof.lap("traffic", t)

static var on := false
static var acc := {}  # key -> microseconds since the benchmark last took them


static func now() -> int:
	return Time.get_ticks_usec() if on else 0


static func lap(key: String, t0: int) -> int:
	if not on:
		return 0
	var t := Time.get_ticks_usec()
	acc[key] = acc.get(key, 0) + t - t0
	return t
