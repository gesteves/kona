module Widgets
  # Returns the article's Plausible view-count markup (eye icon + "Viewed N times" linked to
  # the Plausible dashboard), keyed by Contentful ID. The static site embeds a "Never viewed"
  # placeholder and swaps this in.
  class PlausibleController < BaseController
    def pageviews
      # The standard live-data policy (5 min edge TTL, the default one-hour edge SWR and
      # one-day stale-if-error), matching the other live widgets. The TTL is deliberately the
      # same as `Plausible#query`'s Redis cache: a revalidation after the edge copy expires
      # always finds the Redis entry expired too, so it re-queries Plausible rather than
      # re-rendering the count the edge already had.
      #
      # ⚠️ That alignment is only affordable because the count comes from ONE site-wide query
      # (`Plausible#pageviews_by_path`) shared by every article, rather than a per-article
      # query. Plausible allows 600 calls/hour and the 5-minute cache caps each *cache key* at
      # 12/hour: one shared key is 12 calls/hour flat, while a key per article would scale with
      # the corpus (~60 articles → ~740/hour, over the limit). Don't reintroduce a per-article
      # query here, and don't shorten the TTL on either side without redoing that math.
      cache_widget(ttl: 5.minutes)

      # A malformed id can't be a real entry — collapse the widget before any lookup work
      # (BaseController::CONTENTFUL_ID_FORMAT explains why this matters on /widgets/*).
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

      # nil means the query itself was unavailable → collapse the widget. A path simply absent
      # from the hash means the article has genuinely never been viewed → 0 ("Never viewed").
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
