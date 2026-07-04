module Widgets
  # Returns the article's Plausible view-count markup (eye icon + "Viewed N times" linked to
  # the Plausible dashboard), keyed by Contentful ID. The static site embeds a "Never viewed"
  # placeholder and swaps this in. Cached for an hour — view counts change slowly.
  class PlausibleController < BaseController
    def pageviews
      # Edge SWR kept at a day (vs. the one-hour default): view counts barely change, so
      # serving a stale count while revalidating costs nothing.
      cache_widget(ttl: 1.hour, edge_stale_while_revalidate: 1.day)

      article = Articles.new.find(params[:id])
      return render_empty if article.nil?

      plausible = Plausible.new
      published_at = article.published.presence || article.sys&.first_published_at
      return render_empty if published_at.blank? || plausible.site_id.blank?

      published = DateTime.parse(published_at)
      path = ArticleAttributes.path(slug: article.slug, published_at: published_at)
      return render_empty if path.blank?

      result = plausible.query(metrics: ["pageviews"], date_range: "all", dimensions: [], filters: [["is", "event:page", [path]]])
      return render_empty if result.nil?

      @pageviews = result.dig(:results, 0, :metrics, 0).to_i

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
