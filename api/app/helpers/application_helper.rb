module ApplicationHelper
  # The IANA timezone the site's publish dates are reckoned in.
  #
  # ⚠️ Mirrors the static site's SiteHelpers#site_time_zone, nil included — the controller falls
  # back to the reader's browser zone for a blank value, so a different default here (e.g.
  # TimeZoneResolver.default) would make the same article show the "New" badge in one list and
  # not the other on the same page.
  # @return [String, nil] An IANA timezone id, or nil when unset.
  def site_time_zone
    ENV["TIME_ZONE"].presence
  end
end
