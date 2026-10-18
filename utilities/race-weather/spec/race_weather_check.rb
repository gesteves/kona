# Checks the parts of the race weather tool that need no network: the date parsing, the choice of
# the past dates, the cells of the table, and the course math.
#
# This is plain Ruby, on purpose: the tool has no test framework and does not need one. Run it with
# `ruby spec/race_weather_check.rb`. CI runs it from .github/workflows/utilities.yml, with no
# bundle, thus these files must use the standard library only.
require 'date'
require_relative '../lib/race_weather/course'
require_relative '../lib/race_weather/dates'
require_relative '../lib/race_weather/format'

include RaceWeather

failures = []
checks = 0
check = lambda do |label, actual, expected|
  checks += 1
  failures << "#{label} => #{actual.inspect}, expected #{expected.inspect}" unless actual == expected
end

race = Date.new(2027, 8, 15)

# Date parsing.
check.('parse long form', Dates.parse('August 15, 2027'), race)
check.('parse ISO', Dates.parse('2027-08-15'), race)
check.('parse US slash', Dates.parse('8/15/2027'), race)
check.('parse US slash, zero padded', Dates.parse('08/15/2027'), race)
check.('parse US slash, two-digit year', Dates.parse('8/15/27'), race)
check.('parse day first', Dates.parse('15 Aug 2027'), race)
%w[banana 13/45/2027].push('').each do |text|
  checks += 1
  begin
    Dates.parse(text)
    failures << "parse(#{text.inspect}) should raise ArgumentError"
  rescue ArgumentError
    nil
  end
end

# The Sundays closest to August 15, which this tool must give for a race on Sunday, Aug 15, 2027.
sundays = Dates.past_dates(race, today: Date.new(2026, 10, 8))
check.('past Sundays', sundays, [Date.new(2026, 8, 16), Date.new(2025, 8, 17), Date.new(2024, 8, 18),
                                 Date.new(2023, 8, 13), Date.new(2022, 8, 14)])
check.('each past date is a Sunday', sundays.map(&:wday).uniq, [0])
# A date that is not before today is passed over, and one more year back takes its place.
check.('passes over a date that is not past',
       Dates.past_dates(Date.new(2027, 12, 5), today: Date.new(2026, 10, 8), count: 2),
       [Date.new(2025, 12, 7), Date.new(2024, 12, 8)])
check.('Feb 29 in a common year', Dates.closest_weekday(2027, Date.new(2028, 2, 29)), Date.new(2027, 3, 2))
check.('count', Dates.past_dates(race, today: Date.new(2026, 10, 8), count: 3).size, 3)

# Rain spans and clock labels.
check.('one wet hour', Format.wet_spans([16]), '4 PM')
check.('PM run', Format.wet_spans([15, 16, 17, 18, 19, 20]), '3–9 PM')
check.('run to midnight', Format.wet_spans([22, 23]), '10 PM–midnight')
check.('run across noon', Format.wet_spans([11, 12, 13]), '11 AM–2 PM')
check.('run from noon', Format.wet_spans([12, 13]), 'noon–2 PM')
check.('two runs', Format.wet_spans([3, 4, 16]), '3–5 AM, 4 PM')
check.('midnight hour', Format.clock(0), 'midnight')

# Rain totals.
check.('trace, imperial', Format.rain_amount(0.06, :imperial), 'Trace')
check.('amount, imperial', Format.rain_amount(0.29, :imperial), '0.01"')
check.('amount, imperial, trims zeros', Format.rain_amount(7.62, :imperial), '0.3"')
check.('trace, metric', Format.rain_amount(0.06, :metric), 'Trace')
check.('amount, metric', Format.rain_amount(0.29, :metric), '0.3 mm')

hour = lambda do |local_hour, temp, feels, rh, wind, gust, rain = 0.0|
  { 'localHour' => local_hour, 'temperature' => temp, 'temperatureApparent' => feels, 'humidity' => rh,
    'windSpeed' => wind, 'windGust' => gust, 'precipitationAmount' => rain, 'conditionCode' => 'MostlyClear' }
end
hours = [hour.(6, 15.0, 14.0, 0.7, 5.0, 10.0), hour.(15, 28.3, 28.9, 0.4, 14.5, 27.4, 0.06)]

check.('rain cell', Format.rain(hours, :imperial), 'Trace, 3 PM')
check.('dry rain cell', Format.rain([hours.first], :imperial), 'None')
check.('temperature, imperial', Format.temperature(hours, :imperial), '59°F–83°F (feels like 57°F–84°F)')
check.('temperature, metric', Format.temperature(hours, :metric), '15°C–28°C (feels like 14°C–29°C)')
check.('humidity', Format.humidity(hours), '55%')
check.('wind, imperial', Format.wind(hours, :imperial), 'Up to 9 mph, gusts 17 mph')
check.('wind, metric', Format.wind(hours, :metric), 'Up to 15 km/h, gusts 27 km/h')
check.('condition words', Format.condition_words('MostlyClear'), 'Mostly clear')
check.('AQI category', [50, 51, 101, 151, 201, 301].map { Format.aqi_category(_1) },
       ['Good', 'Moderate', 'Unhealthy for sensitive groups', 'Unhealthy', 'Very unhealthy', 'Hazardous'])

row = Format.row(date: Date.new(2026, 8, 16), hours: hours, phrase: nil, aqi: nil, units: :imperial)
check.('date cell', row.first, 'Aug 16, 2026')
check.('missing cells', [row[1], row.last], ['No data', 'No data'])
check.('header', Format.table([]).lines.first.chomp, '| Date | Weather | Temperature | Humidity | Wind | Rain | AQI |')

# The course: the GPX points, the legs, and the wind of a leg.
gpx = '<trkpt lat="38.0" lon="-121.0"></trkpt><trkpt lon="-121.0" lat="38.001"></trkpt><trkpt lat="38.001" lon="-121.001"/>'
course = Course.points(gpx)
check.('course points', course.size, 3)
check.('course distance', course.last[:meters].round, 199)
check.('course legs', Course.legs(course).map { |leg| leg[:bearing].round }, [0, 270])
check.('headwind', Course.wind_kind(10.0, 0.0, 0.0), :headwind)
check.('tailwind', Course.wind_kind(10.0, 180.0, 0.0), :tailwind)
check.('crosswind', Course.wind_kind(10.0, 90.0, 0.0), :crosswind)
check.('head component wins', Course.wind_kind(20.0, 45.0, 0.0), :headwind)
check.('light wind', Course.wind_kind(7.0, 0.0, 0.0), :light)
check.('wind shares', Course.wind_shares([{ kind: :headwind, weight: 3 }, { kind: :light, weight: 1 }]),
       { headwind: 75, crosswind: 0, tailwind: 0, light: 25 })
check.('duration', [Course.duration_seconds('3:30'), Course.duration_seconds('0:45:30')], [12_600, 2730])

if failures.empty?
  puts "Race weather check: #{checks} checks OK"
else
  warn 'Race weather check FAILED:'
  failures.each { |failure| warn "  - #{failure}" }
  exit 1
end
