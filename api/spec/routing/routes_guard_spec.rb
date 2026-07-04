require "rails_helper"

# Guards for the two load-bearing constraints in config/routes.rb that used to be enforced
# only by ⚠️ comments:
#
#   1. The plain-text 404 catch-all must stay the LAST route — anything added after it is
#      shadowed, and scanner probes go back to raising routing errors instead of clean 404s.
#   2. Every top-level route prefix must be listed in RACK_ATTACK_KNOWN_PREFIXES
#      (config/initializers/rack_attack.rb) — rack-attack throttles anything outside the
#      known prefixes as a scanner probe, so a new top-level route that isn't added there
#      gets its real traffic rate-limited.
RSpec.describe "config/routes.rb guards" do
  # The app's drawn routes (skipping Rails' internal dev-only info routes).
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
