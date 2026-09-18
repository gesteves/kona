# The rules of the Cloudflare `_redirects` file, in the order that source/redirects.erb must
# write them. Refer to web/CLAUDE.md.
module RedirectHelpers
  # Makes a redirect from each synonym of a concept to its canonical archive page. It ignores a
  # synonym with a blank slug, a synonym that is the same as a real tag page, and a synonym that
  # is the same as another redirect.
  #
  # ⚠️ Each synonym gives two rules: with a slash at the end and without one. A `_redirects` rule
  # matches the path exactly, and it runs before `auto-trailing-slash`. Each tag URL of the site
  # ends with a slash, thus a link with one would match no rule and reach the 404 page.
  # @return [Array<Hash>] Items of { from:, to:, status: }.
  def taxonomy_synonym_redirects
    page_paths = data.tags.map { |t| t.tag.path }.to_set
    taken = data.redirects.map(&:from).to_set
    data.tags.flat_map do |entry|
      tag = entry.tag
      Array(tag.synonyms).flat_map do |synonym|
        slug = synonym.to_s.parameterize
        next [] if slug.blank?
        from = "/tagged/#{slug}"
        next [] if page_paths.include?("#{from}/") || taken.include?(from) || taken.include?("#{from}/")
        taken << from << "#{from}/"
        [ from, "#{from}/" ].map { |source| { from: source, to: tag.path, status: 301 } }
      end
    end
  end

  # @param from [String] A redirect source.
  # @return [Boolean] True if Cloudflare counts the rule as "dynamic", that is, the source has
  #   a splat or a :placeholder.
  def dynamic_redirect_source?(from)
    from.include?("*") || from.match?(/:[A-Za-z]/)
  end

  # All the redirect rules, in the order that source/redirects.erb must write them.
  #
  # ⚠️ THE ORDER OF THE RULES IS IMPORTANT. The Cloudflare parser permits 2,000 "static" rules but
  # only 100 "dynamic" rules. It also *latches*: at the first dynamic rule, each subsequent rule
  # counts as dynamic, exact matches included. Write the static rules first, or the deploy fails
  # with only `code: 100324` when the file becomes longer than approximately 100 lines. The static
  # rules first is also the correct match order. This code is outside the template, thus you can
  # test it. Refer to the root and web CLAUDE.md.
  # @return [Array(Array<Hash>, Array<Hash>)] The static rules, then the dynamic rules.
  def partitioned_redirects
    rules =
      [
        { from: "/.well-known/host-meta*", to: "https://fed.brid.gy/.well-known/host-meta:splat", status: 302 },
        { from: "/.well-known/webfinger*", to: "https://fed.brid.gy/.well-known/webfinger", status: 302 }
      ] +
      taxonomy_synonym_redirects.map { |r| { from: r[:from], to: r[:to], status: r[:status] } } +
      data.redirects.map { |r| { from: r.from, to: r.to, status: r.status } }

    # ⚠️ The Cloudflare _redirects file accepts only RELATIVE sources. A `from` with an absolute
    # URL causes a deploy failure (code 100324). The redirects come from Contentful, thus this
    # check is between an incorrect rule and a broken deploy. Put a cross-domain redirect in a
    # zone Bulk Redirect.
    rules.reject! { |r| r[:from].match?(%r{\Ahttps?://}) }
    # ⚠️ The same is true for a 200-status proxy rewrite to an absolute URL. Nothing writes one
    # today, because the Worker does the /pa/* proxy, but the same path could write one.
    rules.reject! { |r| r[:status].to_i == 200 && r[:to].to_s.match?(%r{\Ahttps?://}) }
    # ⚠️ A rule from a path to itself is a loop that Cloudflare accepts, and two rules with one
    # source make the first one the only one. Both come from a person, thus remove them here.
    rules.reject! { |r| normalize_menu_path(r[:from]) == normalize_menu_path(r[:to]) }
    rules.uniq! { |r| r[:from] }

    rules.partition { |r| !dynamic_redirect_source?(r[:from]) }
  end
end
