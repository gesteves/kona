# utilities/race-weather — past race-day weather

A CLI that prints a Markdown table of the weather and the AQI on the past dates that are closest to
a race date. Each past date has the weekday of the race. For a race on Sunday, August 15, 2027, it
gives the Sunday closest to August 15 in each of the 5 years before: Aug 16 2026, Aug 17 2025,
Aug 18 2024, Aug 13 2023, and Aug 14 2022.

It runs on your own machine only. Nothing in `web/` or `api/` depends on it.

## Running it

```bash
cd utilities/race-weather
cp .env.example .env   # then fill in the keys; api/.env has the same ones
bundle install
bundle exec bin/race-weather "Great Falls, Montana" "August 15, 2027"
bundle exec bin/race-weather "Great Falls, Montana" 2027-08-15 --units metric --years 3
```

| Option | Default | Meaning |
|---|---|---|
| `--units` | `imperial` | `imperial` (°F, mph, inches) or `metric` (°C, km/h, mm) |
| `--years` | `5` | The number of past dates |

The date can be in almost any format: `August 15, 2027`, `2027-08-15`, `15 Aug 2027`, or
`8/15/2027`. A slash date is month first.

The table goes to stdout, and the notes go to stderr: the place that Google found, its time zone,
and the sensor of each AQI value. Thus `bin/race-weather … > table.md` gives the table only.

## Weather along a course

`bin/course-weather` gives the weather along a GPX course, at the time of each part of it at an
even speed. WeatherKit gives a forecast for a future hour and the history for a past hour, thus it
works before a race and after it.

```bash
bundle exec bin/course-weather bike.gpx "2026-10-18 08:00" --speed 20
bundle exec bin/course-weather run.gpx "2026-10-18 13:36" --duration 3:30 --every 30
```

| Option | Default | Meaning |
|---|---|---|
| `--speed` | | The average speed, in mph, or in km/h with `--units metric` |
| `--duration` | | The time for the full course, as `H:MM` or `H:MM:SS`. Give this or `--speed` |
| `--units` | `imperial` | `imperial` or `metric` |
| `--every` | `60` | The minutes in one row of the table |
| `--zone` | | An IANA time zone. Without it, Google gives the zone of the start |

The start is a local time at the course. The tool gets one WeatherKit call each 2 km of the
course. A loop or an out-and-back gets fewer calls, because two points in the same cell of about
1 km share one call.

The wind of each leg of 50 m uses the rule of the headwind in the api activity description. The
head component is the wind speed × the cosine of the angle between the wind and the direction of
travel. A leg has a headwind at 8 km/h (5 mph) or more, and a tailwind at −8 km/h or less. Each
other leg has a crosswind when its side component is 8 km/h or more, and a light wind when it is
not. The shares are of the distance, thus they are also of the time at an even speed.

## The columns

Each value is for the full local day, from midnight to midnight in the time zone of the place.

| Column | Source | How |
|---|---|---|
| Date | | The past date |
| Weather | Claude, from the WeatherKit condition of each hour | One short phrase. Refer to `prompts/weather-summary.md`. Without `ANTHROPIC_API_KEY`, the most common condition of the day |
| Temperature | WeatherKit | The lowest and highest air temperature, and the lowest and highest apparent temperature |
| Humidity | WeatherKit | The mean of the 24 hours |
| Wind | WeatherKit | The highest hourly wind speed and the highest gust |
| Rain | WeatherKit | The total, and the hours with any precipitation. Below 0.01" (or 0.1 mm) is `Trace` |
| AQI | PurpleAir | The 24-hour AQI of the nearest outdoor sensor that covers the day. Refer to the text below |

A cell with no data says `No data`. A date with no WeatherKit hours is left out of the table.

## Things worth knowing

- **WeatherKit history starts in August 2021.** A date before that has no row.
- **The AQI comes from one sensor.** The tool looks for sensors in a box of 15 km around the place,
  nearest first. It uses the first sensor that existed on the date and has 18 or more hourly
  readings that day. It applies the EPA humidity correction to each hour, and it changes the mean
  into an AQI value. An hour whose correction is below zero is ignored, as in the api.
- **The EPA math is in `utilities/aqi-map/lib/epa_aqi.rb`**, and this tool loads that file. Thus
  `utilities/` has one copy, and CI checks it. Do not copy it here.
- **The sensor positions and the confidence values are those of today.** The PurpleAir history has
  neither. Thus a sensor that moved is measured from where it is now.
- **The PurpleAir history permits one request each second**, thus each date takes a few seconds.
  Each request also costs API points.
- **Claude can give a different phrase on each run.** The other columns do not change.
