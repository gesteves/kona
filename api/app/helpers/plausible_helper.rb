module PlausibleHelper
  # Formats an article's pageview count, mirroring the web app's old article_views helper.
  # @param pageviews [Integer]
  # @return [String] e.g. "Viewed once", "Viewed 1,234 times", or "Never viewed".
  def pageviews_label(pageviews)
    return "Never viewed" if pageviews.zero?

    times = case pageviews
            when 1 then "once"
            when 2 then "twice"
            else "#{number_to_delimited(pageviews)} times"
            end
    "Viewed #{times}"
  end
end
