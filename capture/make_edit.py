# Builds capture/edit.ps1: cuts the recorded broll.avi into a 5:00 edit with crossfades,
# plus a full-length MP4 of every shot and a contact sheet. Run: python3 make_edit.py
import json
shots = """43-462 globe_day
503-862 globe_dusk
903-1262 globe_night
1303-1722 descent
1747-2166 downtown_orbit
2191-2550 avenue_flyover
2581-3060 construction_wide
3091-3510 construction_close
3551-4030 day_to_night
4071-4430 night_orbit
4461-4760 night_low
4801-5160 ice_cap
5191-5550 belt
5591-5950 golden_city
6011-6370 rain_city
6431-6730 fog_morning
6751-6847 dive
6857-7276 walk_follow
7287-7586 hero_front
7647-8006 crowd_corner
8067-8426 traffic
8492-8941 drive_follow
8947-9246 drive_side
9367-9906 chase
9907-10266 chase_front
10397-10756 golden_drive
10817-11176 night_drive
11282-11701 night_rain_walk
11811-12170 rise"""
S = []
for l in shots.splitlines():
    r, n = l.split()
    a, b = map(int, r.split("-"))
    S.append([n, a, b])
FPS = 30.0
XF = 0.6           # crossfade seconds
TARGET = 300.0
HEAD = 6           # frames dropped at the start of each shot
avail = [(b - a + 1 - HEAD) / FPS for n, a, b in S]
need = TARGET + XF * (len(S) - 1)
# Shorten every shot by the same fraction of its length above 6 s (dive stays whole).
fixed = [min(x, 6.0) for x in avail]
extra = sum(avail) - sum(fixed)
k = (need - sum(fixed)) / extra
dur = [f + (x - f) * k for x, f in zip(avail, fixed)]
print("scale", round(k, 3), "total", round(sum(dur) - XF * (len(S) - 1), 2))
ins, fc = [], []
for i, ((n, a, b), d) in enumerate(zip(S, dur)):
    t0 = (a + HEAD) / FPS
    # centre the kept part in the middle of the shot's motion, leaning to the start
    slack = avail[i] - d
    t0 += slack * 0.35
    ins += ["-ss", "%.3f" % t0, "-t", "%.3f" % d, "-i", "out\\broll.avi"]
    fc.append("[%d:v]setpts=PTS-STARTPTS,format=yuv420p,settb=AVTB[v%d];[%d:a]asetpts=PTS-STARTPTS,aresample=48000[a%d]" % (i, i, i, i))
off = 0.0
pv, pa = "v0", "a0"
for i in range(1, len(S)):
    off += dur[i - 1] - XF
    fc.append("[%s][v%d]xfade=transition=fade:duration=%.2f:offset=%.3f[x%d]" % (pv, i, XF, off, i))
    fc.append("[%s][a%d]acrossfade=d=%.2f[y%d]" % (pa, i, XF, i))
    pv, pa = "x%d" % i, "y%d" % i
    off = off  # offset is from the start of the joined stream
fc.append("[%s]fade=t=in:st=0:d=1,fade=t=out:st=%.2f:d=1.5[vout];[%s]afade=t=in:st=0:d=1,afade=t=out:st=%.2f:d=1.5[aout]" % (pv, TARGET - 1.5, pa, TARGET - 1.5))
open("edit_filter.txt", "w").write(";\n".join(fc))
q = lambda s: "'" + s + "'"
ps = ["# Cuts out\\broll.avi into the b-roll videos. Run from C:\\Users\\russe\\projects\\msp-broll:",
      "#   powershell -ExecutionPolicy Bypass -File repo\\capture\\edit.ps1",
      "$ff = '.\\ffmpeg\\ffmpeg-master-latest-win64-gpl\\bin\\ffmpeg.exe'",
      "$enc = @('-c:v','libx264','-preset','slow','-crf','18','-maxrate','12M','-bufsize','24M','-pix_fmt','yuv420p','-c:a','aac','-b:a','192k','-movflags','+faststart')",
      "Write-Host '1/3  The 5 minute edit'",
      "& $ff -y " + " ".join(q(x) for x in ins) + " -/filter_complex 'repo\\capture\\edit_filter.txt' -map '[vout]' -map '[aout]' @enc -t %d 'out\\MayorStreetPlanet-broll-5min.mp4'" % TARGET,
      "Write-Host '2/3  Every shot, full length'",
      "& $ff -y -i 'out\\broll.avi' @enc 'out\\MayorStreetPlanet-broll-all-shots.mp4'",
      "Write-Host '3/3  Contact sheet'",
      "& $ff -y -i 'out\\MayorStreetPlanet-broll-5min.mp4' -vf 'fps=1/10,scale=480:-1,tile=6x5' -frames:v 1 'out\\contact-sheet.png'",
      "Write-Host 'Done. Files are in out\\'"]
open("edit.ps1", "w", newline="\r\n").write("\n".join(ps) + "\n")
json.dump([{"name": s[0], "secs": round(d, 2)} for s, d in zip(S, dur)], open("edit_cuts.json", "w"), indent=1)
