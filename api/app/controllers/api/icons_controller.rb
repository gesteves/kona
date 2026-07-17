module Api
  # Batch-resolves the web build's Font Awesome allowlist to pre-rendered SVGs. The web app
  # POSTs its committed allowlist tree ({ family => { style => [ids] } }); we resolve each id
  # through the Redis-cached FontAwesome service and return the SVGs in the same tree shape the
  # build's data/icons.json expects. This keeps the Font Awesome integration (token, GraphQL,
  # version, cache) in one place — the web build no longer talks to Font Awesome directly.
  #
  # Bearer-gated (inherited from BaseController): a novel id triggers a paid upstream GraphQL
  # call, so scanners get a cheap 401 before any upstream work. Not edge-cached — it's fetched
  # at build time, and the per-icon SVGs are already durably cached in Redis by FontAwesome.
  class IconsController < BaseController
    # POST; the API_TOKEN bearer check is inherited from BaseController.
    skip_forgery_protection

    def create
      requested = params.to_unsafe_h[:icons]
      return render json: {}, status: :unprocessable_content unless requested.is_a?(Hash)

      fa = FontAwesome.new
      result = {}
      requested.each do |family, styles|
        next unless styles.is_a?(Hash)

        styles.each do |style, ids|
          # uniq: an id repeated within a family/style resolves to the same icon, so emit it
          # once (the web build's allowlist has a few such duplicates).
          Array(ids).uniq.each do |icon_id|
            svg = fa.svg(family, style, icon_id)
            next if svg.blank? # a missing icon is omitted, exactly like the old build-time importer

            ((result[family] ||= {})[style] ||= []) << { id: icon_id, svg: svg }
          end
        end
      end

      render json: result
    end
  end
end
