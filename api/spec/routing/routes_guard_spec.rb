require "rails_helper"

# The tests for the two necessary rules in config/routes.rb, which only a ⚠️ comment gave before:
#
#   1. The plain-text 404 catch-all must stay the LAST route. Rails never reaches a route after it,
#      and a scanner probe then raises a routing error and does not give a clean 404.
#   2. RACK_ATTACK_KNOWN_PREFIXES (config/initializers/rack_attack.rb) must contain each top-level
#      route prefix. rack-attack limits the rate of each path outside those prefixes, because it
#      counts that path as a scanner probe. Thus a new top-level route that is not there gets a rate
#      limit on its true traffic.
RSpec.describe "config/routes.rb guards" do
  # The routes that Rails draws for the app. This does not include the internal info routes of
  # Rails, which exist in development only.
  let(:drawn_routes) { Rails.application.routes.routes.reject(&:internal) }

  it "keeps the *unmatched catch-all as the last route" do
    last_path = drawn_routes.last.path.spec.to_s

    expect(last_path).to start_with("/*unmatched"),
      "The `match \"*unmatched\"` catch-all must stay the LAST route in config/routes.rb — " \
      "any route added after it is shadowed. Found #{last_path.inspect} last instead."
  end

  it "lists every top-level route prefix in RACK_ATTACK_KNOWN_PREFIXES" do
    prefixes = drawn_routes.filter_map do |route|
      path = route.path.spec.to_s.delete_suffix("(.:format)")
      next if path == "/" || path.start_with?("/*") # the root redirect and the catch-all

      "/#{path.split("/")[1]}"
    end.uniq.sort

    unknown = prefixes.reject { |prefix| RACK_ATTACK_KNOWN_ROUTE.call(prefix) }

    expect(unknown).to be_empty,
      "Top-level route prefix(es) #{unknown.join(', ')} are missing from " \
      "RACK_ATTACK_KNOWN_PREFIXES (config/initializers/rack_attack.rb) — rack-attack will " \
      "throttle requests to them as scanner probes. Add the prefix(es) there."
  end
end
