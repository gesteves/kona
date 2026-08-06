module Widgets
  # Renders an article's view count, keyed by Contentful id. The static site embeds a
  # "Never viewed" placeholder and swaps this in.
  class PlausibleController < BaseController
    def pageviews
      # The TTL deliberately matches Plausible#query's own Redis cache, so a revalidation after
      # the edge copy expires finds that entry expired too and re-queries rather than
      # re-rendering the count the edge already had. That alignment is only affordable because
      # the count comes from one site-wide query — see Plausible#pageviews_by_path.
      cache_widget(ttl: 5.minutes)

      # A malformed id can't be a real entry, so collapse before doing any lookup work.
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

      # nil means the query was unavailable, so collapse. A path merely absent from the hash
      # means the article has genuinely never been viewed.
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
