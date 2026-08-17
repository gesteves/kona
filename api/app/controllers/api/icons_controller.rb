module Api
  # Resolves the web build's posted Font Awesome allowlist to pre-rendered SVGs, returned in
  # the same { family => { style => [{ id, svg }] } } tree shape data/icons.json expects. This
  # is what keeps the Font Awesome integration entirely in this app.
  #
  # Bearer-gated, since a novel id triggers a paid upstream call. Not edge-cached: it's fetched
  # at build time, and FontAwesome already caches each SVG durably in Redis.
  class IconsController < BaseController
    skip_forgery_protection

    # ⚠️ A ceiling on the work one request can ask for. Every miss is a billed Font Awesome call
    # plus a Redis key that lives for a year, and the "web posts small batches" convention is the
    # caller's, not something this endpoint enforced. The real allowlist is an order of magnitude
    # under this, so the cap only ever catches a runaway.
    MAX_ICONS = 250

    # Font Awesome's own identifier shape. Anything else can't name a real icon, so it's rejected
    # before it reaches the upstream or mints a cache key.
    SEGMENT_FORMAT = /\A[a-z0-9-]{1,64}\z/

    def create
      requested = params.to_unsafe_h[:icons]
      return render json: {}, status: :unprocessable_content unless requested.is_a?(Hash)

      # Flattened and bounded before a single upstream call, so an oversized request costs nothing
      # rather than being charged for up to the point it's refused.
      triples = wanted_triples(requested)
      if triples.size > MAX_ICONS
        return render json: { error: "Too many icons; the limit is #{MAX_ICONS} per request." },
          status: :unprocessable_content
      end

      fa = FontAwesome.new
      result = triples.each_with_object({}) do |(family, style, icon_id), acc|
        svg = fa.svg(family, style, icon_id)
        next if svg.blank?

        ((acc[family] ||= {})[style] ||= []) << { id: icon_id, svg: svg }
      end

      render json: result
    end

    private

    # Flattens the posted tree into [family, style, id] triples, dropping anything that can't name a
    # real icon. The allowlist has a few duplicates, so an id repeated within a style is one icon.
    # @param requested [Hash] The posted { family => { style => [ids] } } tree.
    # @return [Array<Array(String, String, String)>]
    def wanted_triples(requested)
      requested.flat_map do |family, styles|
        next [] unless styles.is_a?(Hash) && segment?(family)

        styles.flat_map do |style, ids|
          next [] unless segment?(style)

          Array(ids).uniq.filter_map { |id| [ family, style, id ] if segment?(id) }
        end
      end
    end

    # @return [Boolean] Whether a family, style, or icon id can name a real Font Awesome icon.
    def segment?(value)
      value.to_s.match?(SEGMENT_FORMAT)
    end
  end
end
