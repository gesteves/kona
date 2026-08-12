require "rails_helper"

# Each /widgets/* fragment REPLACES a placeholder element in the static build, so the two
# outermost elements must agree on tag and classes — they're what the page's CSS grid lays out.
# The two halves live in separate apps and are edited by hand; until this spec, nothing compared
# them, and the root CLAUDE.md said so in as many words.
#
# Pairs are [web placeholder, api view], both repo-relative.
WIDGET_MARKUP_PAIRS = {
  "activity stats" => [ "source/partials/placeholders/_stats.html.erb", "app/views/widgets/activity_stats/show.html.erb" ],
  "whoop" => [ "source/partials/placeholders/_whoop.html.erb", "app/views/widgets/whoop/show.html.erb" ],
  "current weather" => [ "source/partials/placeholders/_weather.html.erb", "app/views/widgets/weather/current.html.erb" ],
  "article collections" => [ "source/partials/placeholders/_article_collection.html.erb", "app/views/widgets/articles/_collection.html.erb" ],
  "upcoming races" => [ "source/partials/_upcoming_races.html.erb", "app/views/widgets/events/upcoming.html.erb" ],
  "pageviews" => [ "source/partials/article/_full.html.erb", "app/views/widgets/plausible/pageviews.html.erb" ]
}.freeze

RSpec.describe "web placeholder ↔ api fragment markup contract" do
  web_root = Rails.root.join("../web")

  # The live-update root: the first element whose opening tag calls live_update_attrs. Found by
  # marker rather than by position because the pageviews placeholder is an inline span partway
  # down an article partial, not the file's first tag.
  # @param path [Pathname] An ERB template.
  # @return [Hash] { tag:, classes:, nosnippet: }
  def live_update_root(path)
    source = File.read(path)
      .gsub(/<%#.*?%>/m, "")
      .gsub(/<%=\s*live_update_attrs.*?%>/m, "LIVE_UPDATE_ATTRS")
      .gsub(/<%.*?%>/m, "ERB")

    match = source.match(/<([a-z][a-z0-9-]*)\b([^>]*LIVE_UPDATE_ATTRS[^>]*)>/)
    raise "No element calling live_update_attrs in #{path}" if match.nil?

    tag, attrs = match.captures
    { tag: tag, classes: attrs[/class="([^"]*)"/, 1].to_s.split.sort, nosnippet: attrs.include?("data-nosnippet") }
  end

  WIDGET_MARKUP_PAIRS.each do |widget, (placeholder, view)|
    context "the #{widget} widget" do
      let(:web) { live_update_root(web_root.join(placeholder)) }
      let(:api) { live_update_root(Rails.root.join(view)) }

      it "swaps in the same element the placeholder reserved" do
        expect(api[:tag]).to eq(web[:tag])
      end

      it "carries the same classes, so the swap doesn't re-lay-out the section" do
        expect(api[:classes]).to eq(web[:classes])
      end

      it "agrees on data-nosnippet" do
        expect(api[:nosnippet]).to eq(web[:nosnippet])
      end
    end
  end

  # A new widget added without a pair here would silently go back to being hand-synced.
  it "leaves no widget view unpaired" do
    rendered = Dir[Rails.root.join("app/views/widgets/**/*.html.erb")]
      .map { |view| Pathname(view).relative_path_from(Rails.root).to_s }
      .grep_v(%r{/_}) # partials are reached through the view that renders them

    # trending/related are one-line wrappers around the _collection partial paired above.
    covered = WIDGET_MARKUP_PAIRS.values.map(&:last) + %w[
      app/views/widgets/articles/trending.html.erb
      app/views/widgets/articles/related.html.erb
    ]

    expect(rendered - covered).to be_empty
  end

  # ⚠️ This spec lives in the api but reads the web app, and api.yml is path-filtered — so it only
  # runs when a listed path changes. A placeholder outside that filter can be edited with the
  # contract unchecked, which is the failure this whole file exists to prevent. Assert the filter
  # actually covers every placeholder we pair.
  it "is reachable from CI for every placeholder it pairs" do
    workflow = File.read(Rails.root.join("../.github/workflows/api.yml"))
    filters = workflow.scan(%r{^\s*-\s*'(web/[^']+)'$}).flatten.uniq
    expect(filters).not_to be_empty, "api.yml lists no web/ paths — the contract can't fire"

    uncovered = WIDGET_MARKUP_PAIRS.values.map(&:first).reject do |placeholder|
      path = "web/#{placeholder}"
      filters.any? { |filter| File.fnmatch?(filter, path, File::FNM_PATHNAME) || path.start_with?(filter.delete_suffix("**")) }
    end

    expect(uncovered).to be_empty,
      "Not covered by api.yml's paths filter, so editing one skips this spec: #{uncovered.join(', ')}"
  end
end
