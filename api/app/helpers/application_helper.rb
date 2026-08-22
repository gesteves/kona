module ApplicationHelper
  # The IANA timezone of the publish dates of the site.
  #
  # ⚠️ This is the same as SiteHelpers#site_time_zone of the static site, and this includes the nil
  # value. The controller uses the browser zone of the reader for a blank value. Thus a different
  # default here, for example TimeZoneResolver.default, would show the "New" badge on one article in
  # one list and not in the other list, on the same page.
  # @return [String, nil] An IANA timezone id, or nil when it has no value.
  def site_time_zone
    ENV["TIME_ZONE"].presence
  end
end
