module ActivityDescription
  # The position of the sun, from the NOAA approximation. The Intervals.icu weather has no daylight
  # flag, and a clear night does not have the emoji of a clear day.
  # @see https://gml.noaa.gov/grad/solcalc/solareqns.PDF
  module Solar
    # The sun is above the horizon above this elevation, in degrees: the refraction and the size of
    # the sun move the true sunrise below zero.
    SUNRISE_ELEVATION = -0.833

    module_function

    # @param time [Time]
    # @param latitude [Float] In degrees.
    # @param longitude [Float] In degrees, positive to the east.
    # @return [Boolean] True when the sun is above the horizon.
    def daylight?(time, latitude, longitude)
      time = time.utc
      hour = time.hour + (time.min / 60.0) + (time.sec / 3600.0)
      gamma = 2 * Math::PI / 365 * (time.yday - 1 + ((hour - 12) / 24))
      equation_of_time = 229.18 * (0.000075 + (0.001868 * Math.cos(gamma)) - (0.032077 * Math.sin(gamma)) -
                                   (0.014615 * Math.cos(2 * gamma)) - (0.040849 * Math.sin(2 * gamma)))
      declination = 0.006918 - (0.399912 * Math.cos(gamma)) + (0.070257 * Math.sin(gamma)) -
                    (0.006758 * Math.cos(2 * gamma)) + (0.000907 * Math.sin(2 * gamma)) -
                    (0.002697 * Math.cos(3 * gamma)) + (0.00148 * Math.sin(3 * gamma))
      solar_minutes = (hour * 60) + equation_of_time + (4 * longitude)
      hour_angle = ((solar_minutes / 4) - 180) * Math::PI / 180
      lat = latitude * Math::PI / 180
      cos_zenith = (Math.sin(lat) * Math.sin(declination)) + (Math.cos(lat) * Math.cos(declination) * Math.cos(hour_angle))
      elevation = 90 - (Math.acos(cos_zenith.clamp(-1.0, 1.0)) * 180 / Math::PI)
      elevation > SUNRISE_ELEVATION
    end
  end
end
