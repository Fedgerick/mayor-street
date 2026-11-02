class_name Mission
extends RefCounted
## One job, made from a template and real buildings. Built by MissionDirector.generate();
## everything the HUD shows (title, objective, timer, pay) is read from here.

enum State { OFFERED, ACTIVE, PASSED, FAILED }

var template: Dictionary
var id: String
var side: String          # "good" or "bad"
var giver: String         # "radio" or "payphone"
var title: String
var brief: String
var slots := {}           # slot -> {building, name, cell (road tile out front), pos (Vector3)}
var vars := {}            # extra text fields, e.g. car
var steps: Array = []     # template steps with text filled in
var route_m := 0.0        # road metres along the template's route
var risk := 1.0
var pay := 0
var city_bonus := 0
var goodness := 0.0
var crime := 0
var time_limit := 0.0     # seconds, 0 = untimed
var max_wanted := 99
var quest := ""           # quest id when a quest started this job
var contact := ""         # who the job is for (contacts.gd)
var story := false        # handed out by a story quest: intro, medal, replay
var replay := false       # replayed from the quest log: half pay, no other rewards

var state := State.OFFERED
var step_i := 0
var time_left := 0.0
var hold := 0.0           # seconds held in a hold step
var points: Array[Vector3] = []  # collect step: what is left to pick up
var fail_reason := ""
var mission_car: Object = null
var tow_car: Object = null   # tow step: the car to hook, then carried on the truck's deck
var tow_on := false
var target: ChaseCar = null  # chase step: the car to stop
var elapsed := 0.0        # seconds since the job started (medals)
var damage := 0.0         # health and car damage taken during the job (medals)
var _damage0 := 0.0
var _escape_t := 0.0
var left := -1            # fight / rampage / race: what is still to do, for {left} (-1: piles left)
var step_time := 0.0      # defend / rampage: seconds left in this step, for {secs}
var off_post := 0.0       # defend: seconds spent away from the spot
var kills0 := 0           # rampage: the kill count when the step began


func step() -> Dictionary:
	return steps[step_i] if step_i < steps.size() else {}


func step_pos() -> Vector3:
	var s := step()
	if s.has("at") and slots.has(s.at):
		return slots[s.at].pos
	return Vector3.INF


func objective() -> String:
	var s := step()
	var text: String = s.get("text", "")
	text = text.replace("{left}", str(left if left >= 0 else points.size()))
	return text.replace("{secs}", str(ceili(step_time)))


func format(text: String) -> String:
	for k in slots:
		text = text.replace("{%s}" % k, slots[k].name)
	for k in vars:
		text = text.replace("{%s}" % k, str(vars[k]))
	return text


func km() -> float:
	return route_m / 1000.0


func summary() -> String:
	## One line for offers and the quest log: "Fare to Lucky Pawn, 1.2 km, $230".
	return "%s  -  %.1f km  -  $%d" % [title, km(), pay]
