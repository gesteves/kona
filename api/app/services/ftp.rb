# A cycling FTP from POST /api/ftp. It parses the input and adds one job for each destination: the
# Ride sport settings of Intervals.icu and the profile of the athlete on Strava.
class Ftp
  # The range of a correct FTP in watts. A value outside it is a typing error.
  RANGE_W = (50..700)

  # Parses an FTP and rounds it to whole watts. Both destinations store an integer.
  #
  # ⚠️ It parses with Float(), and not with to_f. to_f changes text that it cannot parse into 0.0.
  # @param value [String, Numeric, nil] The FTP in watts.
  # @return [Integer, nil] The FTP in watts, or nil if the value is incorrect.
  def self.parse(value)
    ftp = Float(value, exception: false)
    return if ftp.nil? || !ftp.finite?

    watts = ftp.round
    watts if RANGE_W.cover?(watts)
  end

  # Adds the two sync jobs.
  # @param watts [Integer] The FTP in watts.
  def self.save(watts)
    IntervalsFtpJob.perform_async(watts)
    StravaFtpJob.perform_async(watts)
  end
end
