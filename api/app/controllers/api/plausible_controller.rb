module Api
  # Returns the article's Plausible view-count markup (eye icon + "Viewed N times" linked to
  # the Plausible dashboard), keyed by Contentful ID. The static site embeds a "Never viewed"
  # placeholder and swaps this in. Cached for an hour — view counts change slowly.
  class PlausibleController < BaseController
    def pageviews
      cache_widget(ttl: 1.hour)

      article = Articles.new.find(params[:id])
      return render_empty if article.nil?

      published_at = article.published.presence || article.sys&.first_published_at
      site_id = ENV["PLAUSIBLE_SITE_ID"]
      return render_empty if published_at.blank? || site_id.blank?

      published = DateTime.parse(published_at)
      path = "/#{published.strftime('%Y/%m/%d')}/#{article.slug}/"

      result = Plausible.new.query(metrics: ["pageviews"], date_range: "all", dimensions: [], filters: [["is", "event:page", [path]]])
      return render_empty if result.nil?

      @pageviews = result.dig(:results, 0, :metrics, 0).to_i

      tz = TimeZoneResolver.default
      from = published.in_time_zone(tz).strftime("%Y-%m-%d")
      to = Time.current.in_time_zone(tz).strftime("%Y-%m-%d")
      # URL-encode the path before interpolating it into the query string; a slug containing
      # URL-special characters would otherwise corrupt the f=is,page filter / inject params.
      encoded_path = ERB::Util.url_encode(path)
      @plausible_url = "https://plausible.io/#{site_id}?f=is,page,#{encoded_path}&period=custom&from=#{from}&to=#{to}&r=v2"

      render :pageviews
    end
  end
end
