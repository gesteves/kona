module Widgets
  # Renders the view count of an article, with the Contentful id as the key. The static site has a
  # "Never viewed" placeholder, and this fragment replaces it.
  class PlausibleController < BaseController
    def pageviews
      # The TTL is the same as the Redis cache of Plausible#query, on purpose. Thus a request after
      # the edge copy expires finds that the Redis entry also expired, and it does the query again
      # and does not render the same count that the edge already had. This is possible only because
      # the count comes from one query for the full site. Refer to Plausible#pageviews_by_path.
      cache_widget(ttl: 5.minutes)

      # An id with an incorrect shape can name no true entry, thus the widget goes away before any
      # lookup.
      id = contentful_id_param
      return render_empty if id.nil?

      article = Articles.new.find(id)
      return render_empty if article.nil?

      plausible = Plausible.new
      published_at = article.published.presence || article.sys&.first_published_at
      return render_empty if published_at.blank? || plausible.site_id.blank?

      published = DateTime.parse(published_at)
      path = ArticleAttributes.path(slug: article.slug, published_at: published_at)
      return render_empty if path.blank?

      # A nil means that the query was not available, thus the widget goes away. A path that is
      # absent from the hash means that nobody read the article.
      pageviews_by_path = plausible.pageviews_by_path(date_range: "all")
      return render_empty if pageviews_by_path.nil?

      @pageviews = pageviews_by_path[path].to_i

      tz = TimeZoneResolver.default
      @plausible_url = plausible.dashboard_url(
        path: path,
        from: published.in_time_zone(tz).strftime("%Y-%m-%d"),
        to: Time.current.in_time_zone(tz).strftime("%Y-%m-%d")
      )

      render :pageviews
    end
  end
end
