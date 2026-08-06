module Api
  # Resolves the web build's posted Font Awesome allowlist to pre-rendered SVGs, returned in
  # the same { family => { style => [{ id, svg }] } } tree shape data/icons.json expects. This
  # is what keeps the Font Awesome integration entirely in this app.
  #
  # Bearer-gated, since a novel id triggers a paid upstream call. Not edge-cached: it's fetched
  # at build time, and FontAwesome already caches each SVG durably in Redis.
  class IconsController < BaseController
    skip_forgery_protection

    def create
      requested = params.to_unsafe_h[:icons]
      return render json: {}, status: :unprocessable_content unless requested.is_a?(Hash)

      fa = FontAwesome.new
      result = {}
      requested.each do |family, styles|
        next unless styles.is_a?(Hash)

        styles.each do |style, ids|
          # The allowlist has a few duplicates; an id repeated within a style is one icon.
          Array(ids).uniq.each do |icon_id|
            svg = fa.svg(family, style, icon_id)
            next if svg.blank?

            ((result[family] ||= {})[style] ||= []) << { id: icon_id, svg: svg }
          end
        end
      end

      render json: result
    end
  end
end
