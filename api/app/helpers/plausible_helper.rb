module PlausibleHelper
  # Makes the text of the pageview count of an article. It is the same as the article_views helper
  # that the web app had.
  # @param pageviews [Integer]
  # @return [String] For example "Viewed once", "Viewed 1,234 times", or "Never viewed".
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
