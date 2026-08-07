# The EPA's PurpleAir correction and the PM2.5 → AQI conversion.
#
# ⚠️ Ported (minus ActiveSupport) from api/app/services/purple_air.rb. `utilities/` must not
# depend on `api/`, so this is duplication by design — and it means a correction upstream will not
# reach this copy on its own. It lives in its own file, rather than inline in app.rb, so the two
# implementations can be diffed directly and so spec/epa_aqi_check.rb can exercise it without
# booting Sinatra. Run that check after touching either copy; CI runs it too.
#
# If a map here disagrees with the site's own AQI widget, diff this against the api's version first.
module EpaAqi
  extend self

  # Applies the EPA humidity correction to raw PM2.5.
  # @see https://cfpub.epa.gov/si/si_public_record_report.cfm?dirEntryId=353088&Lab=CEMM
  def apply_epa_correction(pm25, humidity)
    return if pm25.nil?
    return pm25 if humidity.nil?

    # The correction is only defined for non-negative PM2.5; sensors do report slightly negative
    # values in clean air, and without this they'd fall past every band to the high-concentration
    # polynomial and come back "Hazardous".
    return 0.0 if pm25.negative?

    case pm25
    when 0...30
      0.524 * pm25 - 0.0862 * humidity + 5.75
    when 30...50
      # Transition band: blend the low and mid corrections by w = pm25/20 - 1.5 (0→1 across the band).
      w = pm25 / 20.0 - 1.5
      ((0.786 * w + 0.524 * (1 - w)) * pm25) - 0.0862 * humidity + 5.75
    when 50...210
      0.786 * pm25 - 0.0862 * humidity + 5.75
    when 210...260
      # Transition band: blend the mid and high corrections by w = pm25/50 - 4.2 (0→1 across the band).
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

  # Converts PM2.5 to an AQI value. (The api's version also returns a category and description;
  # the map only needs the number, since the color comes from a Mapbox expression.)
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
