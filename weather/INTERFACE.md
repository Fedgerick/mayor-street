# Weather

`weather/weather.gd` (class `Weather`, a Node). Clear, cloudy, rain and fog, changing over the game days.

## Wiring (main.gd)

```gdscript
weather = Weather.new()
weather.name = "Weather"
add_child(weather)
weather.setup(city)                  # follows city.minutes, so game speed and pause apply
life.set_weather(weather)            # crowd and traffic react
var rain_fx := RainFX.new()          # weather/rain_fx.gd: rain and splashes near the camera
add_child(rain_fx)
rain_fx.setup(weather, cam)          # call rain_fx.set_camera(street_cam) when the camera changes
rain_fx.set_quality(level)           # 0 low, 1 medium, 2 high (number of drops)
Progress.register_section("weather", weather)   # optional: to_dict/from_dict keep a forced state
```

## What it gives

Eased values, 0..1, updated every frame: `cloud`, `rain`, `fog`, `wind`, `wet` (street wetness: soaks in about 15 game minutes of rain, dries over about 2.5 game hours, faster in the midday sun).

- `kind` (`Weather.Kind.CLEAR`, `CLOUDY`, `RAIN`, `FOG`), `state_name()`, `signal changed(kind)`.
- `grip()`: 1 dry .. 0.7 on soaked roads. **For the player car:** multiply tyre grip by it.
- `visibility()`: 1 .. 0.25 in thick fog.
- `umbrella_share()`.
- `set_weather(kind, instant := false)`: force a state for a mission or the debug menu; `set_weather(-1)` goes back to the calendar.
- `scheduled(minutes)`: what the calendar has at a game time. Each quarter of a day picks a state from the city seed, and fog only comes at night and in the morning.

## Hooks for the sky, roads and buildings (City sandbox thread)

If the project declares any of these global shader uniforms (Project Settings, Shader Globals, all `float`), Weather sets them every frame: `weather_cloud`, `weather_rain`, `weather_fog`, `weather_wet`, `weather_wind`. Suggested uses:

- sky and sun: darken and grey the sky and lower the sun energy by `weather_cloud`; thicken fog by `weather_fog`
- roads: `weather_wet` darkens the asphalt and raises its specular and lowers its roughness; on High a screen-space or planar reflection fades in with it, on Med a faked reflection (a sky-coloured fresnel sheen)
- puddles from the dresser's ground-wear decals: show with `weather_wet`
- trees and rain streaks: sway with `weather_wind`

## Tests

`godot --headless --path . --script res://weather/tests/test_weather.gd`
