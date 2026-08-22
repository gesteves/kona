module Api
  # Changes the Font Awesome list that the web build posts into rendered SVGs. It returns them in
  # the same { family => { style => [{ id, svg }] } } tree that data/icons.json needs. This is what
  # keeps the Font Awesome integration in this app only.
  #
  # It needs a bearer token, because a new id causes an upstream call that costs money. The edge
  # does not cache it: the build gets it, and FontAwesome already keeps each SVG in Redis.
  class IconsController < BaseController
    skip_forgery_protection

    # ⚠️ This is the maximum work for one request. Each icon that is not in the cache is a Font
    # Awesome call that costs money and a Redis key that stays for a year. The rule that web posts
    # small groups belongs to the caller, and this endpoint did not enforce it. The true list is ten
    # times smaller than this limit, thus the limit catches only a request that is much too
    # large.
    MAX_ICONS = 250

    # The identifier shape of Font Awesome. Each other value can name no true icon, thus the code
    # refuses it before it reaches the upstream service or makes a cache key.
    SEGMENT_FORMAT = /\A[a-z0-9-]{1,64}\z/

    def create
      requested = params.to_unsafe_h[:icons]
      return render json: {}, status: :unprocessable_content unless requested.is_a?(Hash)

      # The code makes one list and applies the limit before the first upstream call. Thus a request
      # that is too large costs nothing, and the code does not pay for the icons before the
      # refusal.
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

    # Changes the tree from the request into [family, style, id] items, and removes each item that
    # can name no true icon. The list has some copies, thus an id that appears more than one time in
    # a style is one icon.
    # @param requested [Hash] The { family => { style => [ids] } } tree from the request.
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

    # @return [Boolean] True if a family, a style, or an icon id can name a true Font Awesome
    #   icon.
    def segment?(value)
      value.to_s.match?(SEGMENT_FORMAT)
    end
  end
end
