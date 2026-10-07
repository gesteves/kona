# Writes a cycling FTP to the Ride sport settings of Intervals.icu. Api::FtpController adds it to the
# queue. The PUT sets two values, thus a retry is safe.
class IntervalsFtpJob < ApplicationJob
  # ⚠️ It also sets `indoor_ftp`. That field has a value, and Intervals.icu uses it for an indoor
  # ride. Without it, the old indoor value stays in effect.
  # @param watts [Integer] The FTP in watts.
  def perform(watts)
    Intervals.new.update_sport_settings!("Ride", ftp: watts, indoor_ftp: watts)
    Rails.logger.info("FTP synced to Intervals.icu (#{watts} W)")
  end
end
