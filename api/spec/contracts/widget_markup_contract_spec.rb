require "rails_helper"

# Each /widgets/* fragment REPLACES a placeholder element in the static build. Thus the two
# outermost elements must have the same tag and the same classes, because the CSS grid of the page
# lays them out. The two halves are in two apps and a person edits each one. Before this spec,
# nothing compared them, and the root CLAUDE.md said so.
#
# Each pair is [the web placeholder, the api view], and both paths start at the root of the repo.
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

  # The live-update root: the first element whose opening tag calls live_update_attrs. The code finds
  # it by that call and not by its position, because the pageviews placeholder is a span in the
  # middle of an article partial, and not the first tag of the file.
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

  # A new widget with no pair here would go back to a sync by hand, with no message.
  it "leaves no widget view unpaired" do
    rendered = Dir[Rails.root.join("app/views/widgets/**/*.html.erb")]
      .map { |view| Pathname(view).relative_path_from(Rails.root).to_s }
      .grep_v(%r{/_}) # partials are reached through the view that renders them

    # trending is one line around the _collection partial, which is in a pair above.
    covered = WIDGET_MARKUP_PAIRS.values.map(&:last) + %w[
      app/views/widgets/articles/trending.html.erb
    ]

    expect(rendered - covered).to be_empty
  end

  # ⚠️ This spec is in the api but it reads the web app, and api.yml has a path filter. Thus the spec
  # runs only when a path in that list changes. A person can edit a placeholder outside that filter
  # and nothing checks the contract, and this file exists to prevent that failure. This example
  # checks that the filter covers each placeholder in a pair.
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
