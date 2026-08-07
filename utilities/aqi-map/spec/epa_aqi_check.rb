# Golden vectors for the EPA correction and the PM2.5 → AQI conversion.
#
# ⚠️ The expected values are computed from the **published equation**, not from what either
# implementation happens to return. That distinction is the whole point: lib/epa_aqi.rb is a
# hand-maintained copy of api/app/services/purple_air.rb, so a table generated from the code would
# happily enshrine a bug in both places. (One already slipped through this way — an 8.841e-4 where
# the equation says 8.84e-4 — and the api's spec had the wrong value baked into its expectation.)
#
# Plain Ruby on purpose: this app has no test framework and doesn't warrant one.
# Run with `ruby spec/epa_aqi_check.rb`; CI runs it from .github/workflows/utilities.yml.
#
# @see https://cfpub.epa.gov/si/si_public_record_report.cfm?dirEntryId=353088&Lab=CEMM
require_relative '../lib/epa_aqi'

RH = 40.0

# [pm25, humidity, expected corrected pm2.5] — one per band, plus both band boundaries.
CORRECTION_VECTORS = [
  # 0 ≤ x < 30: 0.524x - 0.0862·RH + 5.75
  [10.0, RH, 7.542],
  # 30 ≤ x < 50, w = x/20 - 3/2 → at x=40, w=0.5
  [40.0, RH, 28.502],
  # continuous at the 30 boundary (w = 0 → low formula)
  [30.0, RH, 0.524 * 30.0 - 0.0862 * RH + 5.75],
  # 50 ≤ x < 210: 0.786x - 0.0862·RH + 5.75
  [100.0, RH, 80.902],
  # 210 ≤ x < 260, w = x/50 - 21/5 → at x=235, w=0.5
  [235.0, RH, 200.473],
  # continuous at the 210 boundary (w = 0 → mid formula)
  [210.0, RH, 0.786 * 210.0 - 0.0862 * RH + 5.75],
  # 260 ≤ x: 2.966 + 0.69x + 8.84e-4·x²  ⚠️ PLUS 8.84e-4, not 8.841e-4 and not minus
  [300.0, RH, 2.966 + 0.69 * 300.0 + 8.84e-4 * 300.0**2],
  [500.0, RH, 2.966 + 0.69 * 500.0 + 8.84e-4 * 500.0**2],
  # Outside the equation's domain: sensors report slightly negative PM2.5 in clean air, and it
  # must not fall through to the high-concentration polynomial.
  [-2.0, RH, 0.0],
  # No humidity reading: the raw value passes through uncorrected.
  [12.0, nil, 12.0]
].freeze

# [corrected pm2.5, expected AQI] — the breakpoint table's ends.
AQI_VECTORS = [
  [0.0, 0], [9.0, 50], [9.1, 51], [35.4, 100], [35.5, 101],
  [55.4, 150], [55.5, 151], [125.4, 200], [125.5, 201], [225.4, 300]
].freeze

failures = []

CORRECTION_VECTORS.each do |pm25, humidity, expected|
  actual = EpaAqi.apply_epa_correction(pm25, humidity)
  next if actual && (actual - expected).abs < 0.001

  failures << "apply_epa_correction(#{pm25}, #{humidity.inspect}) => #{actual.inspect}, expected #{expected}"
end

AQI_VECTORS.each do |pm25, expected|
  actual = EpaAqi.format_aqi(pm25)
  next if actual == expected

  failures << "format_aqi(#{pm25}) => #{actual.inspect}, expected #{expected}"
end

failures << "format_aqi(nil) should be nil" unless EpaAqi.format_aqi(nil).nil?
failures << "apply_epa_correction(nil, 40) should be nil" unless EpaAqi.apply_epa_correction(nil, RH).nil?

if failures.empty?
  puts "EPA AQI check: #{CORRECTION_VECTORS.size + AQI_VECTORS.size + 2} vectors OK"
else
  warn "EPA AQI check FAILED:"
  failures.each { |failure| warn "  - #{failure}" }
  warn "\nCompare lib/epa_aqi.rb against api/app/services/purple_air.rb, and both against the"
  warn "published equation — the vectors above come from the equation, not from either copy."
  exit 1
end
