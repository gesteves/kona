module PlausibleHelper
  # The name of the Plausible goal for a click on a link into an article. ⚠️ The goal in the
  # dashboard must have this exact text. Plausible drops an event that no goal matches, and it does
  # not fill in the data from before. Web has a copy in lib/helpers/site_helpers.rb, and
  # spec/contracts/article_click_contract_spec.rb compares the two.
  ARTICLE_CLICK_EVENT = "Article Click"

  # Makes the Plausible tagged-event classes for a link into an article. The tracking script of the
  # static page reads the class names of the link and sends one event, with the section and the
  # destination URL.
  # ⚠️ A section name must have no space, no "=", and no "--": the script parses the class name.
  # ⚠️ It gives nil for a blank section. The name class on its own sends an event with no section,
  # and nothing shows that error.
  # @param section [String] The analytics name of the section that holds the link.
  # @return [String, nil] The class names, or nil.
  def article_click_classes(section)
    return if section.blank?

    "plausible-event-name=#{ARTICLE_CLICK_EVENT.tr(' ', '+')} plausible-event-section=#{section}"
  end

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
