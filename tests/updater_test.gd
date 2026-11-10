extends SceneTree
## Updater against a local stand-in for GitHub: version compare, the offer, and the download.
##   python3 -m http.server serves tests/updater_fixture (see run line in the test output);
##   godot --headless --script res://tests/updater_test.gd -- --update-url=http://127.0.0.1:PORT/latest.json

var fails := 0


func check(ok: bool, what: String) -> void:
	print(("PASS " if ok else "FAIL ") + what)
	if not ok:
		fails += 1


func _initialize() -> void:
	check(Updater.is_newer("v0.4.19", "0.4.18"), "0.4.19 is newer than 0.4.18")
	check(Updater.is_newer("v0.5.0", "0.4.18"), "0.5.0 is newer than 0.4.18")
	check(Updater.is_newer("0.4.18.1", "0.4.18"), "0.4.18.1 is newer than 0.4.18")
	check(not Updater.is_newer("v0.4.18", "0.4.18"), "same version is not newer")
	check(not Updater.is_newer("v0.4.9", "0.4.18"), "0.4.9 is older than 0.4.18")
	var url := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--update-url="):
			url = a.trim_prefix("--update-url=")
	if url == "":
		print("no --update-url: skipped the download part")
		quit(1 if fails else 0)
		return
	_download(url)


func _download(url: String) -> void:
	var up := Updater.new()
	up.url = url
	up.test_mode = true
	root.add_child(up)
	var state: String = await up.finished
	check(state == "offered", "a newer release is offered (got %s)" % state)
	check(up.latest == "99.0.0", "latest tag read")
	up.update_now()
	state = await up.finished
	check(state == "downloaded", "installer downloaded (got %s)" % state)
	var f := FileAccess.get_file_as_string(OS.get_user_data_dir().path_join(Updater.ASSET))
	check(f == "fake installer\n", "downloaded file matches")
	DirAccess.remove_absolute(OS.get_user_data_dir().path_join(Updater.ASSET))
	quit(1 if fails else 0)
