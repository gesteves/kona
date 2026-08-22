# The PurpleAir correction of the EPA, and the conversion of PM2.5 into an AQI value.
#
# ⚠️ This code comes from api/app/services/purple_air.rb, without ActiveSupport. `utilities/` must
# not depend on `api/`, thus this copy is correct, on purpose. It also means that a correction in
# the other file does not reach this copy by itself. It is in its own file, and not in app.rb, thus
# you can compare the two files directly and spec/epa_aqi_check.rb can run it with no Sinatra. Run
# that check after you change one of the two copies. CI also runs it.
#
# If a map here does not agree with the AQI widget of the site, compare this file with the version
# in the api first.
module EpaAqi
  extend self

  # Applies the EPA humidity correction to a raw PM2.5 value.
  # @see https://cfpub.epa.gov/si/si_public_record_report.cfm?dirEntryId=353088&Lab=CEMM
  def apply_epa_correction(pm25, humidity)
    return if pm25.nil?
    return pm25 if humidity.nil?

    # The correction applies only to a PM2.5 value of zero or more. A sensor gives a small negative
    # value in clean air, and without this check that value would go past each band to the
    # polynomial for a high concentration and give "Hazardous".
    return 0.0 if pm25.negative?

    case pm25
    when 0...30
      0.524 * pm25 - 0.0862 * humidity + 5.75
    when 30...50
      # The transition band: mix the low correction and the middle correction with
      # w = pm25/20 - 1.5, which goes from 0 to 1 across the band.
      w = pm25 / 20.0 - 1.5
      ((0.786 * w + 0.524 * (1 - w)) * pm25) - 0.0862 * humidity + 5.75
    when 50...210
      0.786 * pm25 - 0.0862 * humidity + 5.75
    when 210...260
      # The transition band: mix the middle correction and the high correction with
      # w = pm25/50 - 4.2, which goes from 0 to 1 across the band.
      w = pm25 / 50.0 - 4.2
      ((0.69 * w + 0.786 * (1 - w)) * pm25) -
        0.0862 * humidity * (1 - w) +
        2.966 * w +
        5.75 * (1 - w) +
        8.84e-4 * pm25**2 * w
    else
      2.966 + 0.69 * pm25 + 8.84e-4 * pm25**2
    end
  end

  # Changes a PM2.5 value into an AQI value. The version in the api also gives a category and a
  # description. The map needs only the number, because the color comes from a Mapbox expression.
  # @see https://www.epa.gov/system/files/documents/2024-02/pm-naaqs-air-quality-index-fact-sheet.pdf
  def format_aqi(pm25)
    return if pm25.nil?
    pm25 = pm25.round(1)

    case pm25
    when 0..9.0     then calculate_aqi(pm25, 0, 9.0, 0, 50)
    when 9.1..35.4  then calculate_aqi(pm25, 9.1, 35.4, 51, 100)
    when 35.5..55.4 then calculate_aqi(pm25, 35.5, 55.4, 101, 150)
    when 55.5..125.4 then calculate_aqi(pm25, 55.5, 125.4, 151, 200)
    when 125.5..225.4 then calculate_aqi(pm25, 125.5, 225.4, 201, 300)
    else calculate_aqi(pm25, 225.5, 500.0, 301, 500)
    end
  end

  def calculate_aqi(pm25, pm25_low, pm25_high, aqi_low, aqi_high)
    pm25 = pm25.round(1)
    if pm25 > 500
      (((aqi_high - aqi_low) / (pm25_high - pm25_low)) * (pm25 - pm25_high) + aqi_high).round
    else
      ((((aqi_high - aqi_low) / (pm25_high - pm25_low)) * (pm25 - pm25_low)) + aqi_low).round
    end
  end
end
