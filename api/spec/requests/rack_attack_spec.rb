require "rails_helper"

# Rack::Attack is disabled in the test env so the rest of the suite isn't rate-limited; these
# examples flip it on and use the in-memory store configured for test, resetting counters
# around each example so they don't leak across the shared 127.0.0.1 client IP.
RSpec.describe "Rack::Attack", type: :request do
  before do
    Rack::Attack.enabled = true
    Rack::Attack.cache.store.clear
  end

  after do
    Rack::Attack.cache.store.clear
    Rack::Attack.enabled = false
  end

  it "does not throttle or block legitimate (known-route) traffic" do
    30.times { get "/up" }

    expect(response).to have_http_status(:ok)
  end

  it "blocks scanner probes for secrets/dotfiles at the middleware" do
    get "/api/.env"
    expect(response).to have_http_status(:forbidden)
    expect(response.body).to eq("403 Forbidden\n")

    get "/wp-login.php"
    expect(response).to have_http_status(:forbidden)
  end

  it "blocks probe paths by pattern without banning the IP for anything else" do
    4.times do
      get "/api/.env"
      expect(response).to have_http_status(:forbidden)
    end

    # The block is path-scoped, not an IP ban: legitimate traffic from the same IP still works.
    get "/up"
    expect(response).to have_http_status(:ok)
  end

  # Regression: probe requests can arrive through the public web proxy, where they come in
  # on a SHARED egress IP. Blocking one must never ban that IP, or every visitor's widgets
  # would 403 at once. (This is the bug that took the site down: an IP-based Fail2Ban here.)
  it "does not let a probe ban the shared proxy IP it arrives on" do
    get "/api/status" # matches the probe pattern
    expect(response).to have_http_status(:forbidden)

    # Same IP, a legitimate request — must be unaffected.
    get "/up"
    expect(response).to have_http_status(:ok)
  end

  describe "RACK_ATTACK_PROBE_PATH (probe detection)" do
    it "matches probe paths, including percent-encoded ones scanners use to evade matching" do
      expect(RACK_ATTACK_PROBE_PATH.call("/.env")).to be_truthy
      expect(RACK_ATTACK_PROBE_PATH.call("/wp-login.php")).to be_truthy
      expect(RACK_ATTACK_PROBE_PATH.call("/app/%2Eenv")).to be_truthy        # /app/.env
      expect(RACK_ATTACK_PROBE_PATH.call("/%2Egit/config")).to be_truthy     # /.git/config
    end

    it "leaves legitimate paths alone" do
      expect(RACK_ATTACK_PROBE_PATH.call("/widgets/weather/current")).to be_falsey
      expect(RACK_ATTACK_PROBE_PATH.call("/up")).to be_falsey
      # .well-known is where legitimate endpoints live (security.txt, did:web, OAuth metadata) —
      # blocking it would silently 403 a future one, so probes there just 404 via the catch-all.
      expect(RACK_ATTACK_PROBE_PATH.call("/.well-known/security.txt")).to be_falsey
    end

    it "is safe on malformed encoding (treats it as a non-probe rather than raising)" do
      expect { RACK_ATTACK_PROBE_PATH.call("/%ZZ%2") }.not_to raise_error
      expect(RACK_ATTACK_PROBE_PATH.call("/%ZZ%2")).to be_falsey
    end
  end

  it "throttles an IP hammering paths outside the known routes" do
    20.times { get "/no-such-page" }
    expect(response).not_to have_http_status(:too_many_requests)

    get "/no-such-page"
    expect(response).to have_http_status(:too_many_requests)
    expect(response.body).to eq("429 Too Many Requests\n")
  end

  # The throttle must key on the real client (Fly-Client-IP), not the shared transport IP — so one
  # abusive client can't exhaust the budget for everyone behind the same fly proxy address.
  it "throttles per real client IP from Fly-Client-IP, isolating distinct clients" do
    21.times { get "/no-such-page", headers: { "Fly-Client-IP" => "1.1.1.1" } }
    expect(response).to have_http_status(:too_many_requests)

    # A different client (same transport, different Fly-Client-IP) keeps its own budget.
    get "/no-such-page", headers: { "Fly-Client-IP" => "2.2.2.2" }
    expect(response).not_to have_http_status(:too_many_requests)
  end

  # Behind Cloudflare, fly sees a Cloudflare edge node as its client, so Fly-Client-IP is the same
  # PoP address for every visitor. CF-Connecting-IP carries the true client and must win, or the
  # throttle collapses into a single global bucket keyed on the PoP.
  it "prefers CF-Connecting-IP over Fly-Client-IP, isolating clients behind one Cloudflare PoP" do
    21.times do
      get "/no-such-page",
          headers: { "CF-Connecting-IP" => "1.1.1.1", "Fly-Client-IP" => "172.70.0.1" }
    end
    expect(response).to have_http_status(:too_many_requests)

    # A different visitor arriving through the SAME Cloudflare PoP keeps its own budget.
    get "/no-such-page",
        headers: { "CF-Connecting-IP" => "2.2.2.2", "Fly-Client-IP" => "172.70.0.1" }
    expect(response).not_to have_http_status(:too_many_requests)
  end

  # Traffic that reaches fly without passing through Cloudflare has no CF-Connecting-IP; it must
  # still be keyed on the real client. (This path is live: during DNS propagation, and via any
  # route that bypasses the Cloudflare zone.)
  it "falls back to Fly-Client-IP when CF-Connecting-IP is absent" do
    21.times { get "/no-such-page", headers: { "Fly-Client-IP" => "3.3.3.3" } }
    expect(response).to have_http_status(:too_many_requests)

    get "/no-such-page", headers: { "Fly-Client-IP" => "4.4.4.4" }
    expect(response).not_to have_http_status(:too_many_requests)
  end

  # The contact form throttles per REAL visitor IP — the one the web proxy forwards as
  # X-Kona-Client-IP — not the shared proxy egress. It's a throttle (429), never a ban, so it
  # can't take down the shared proxy IP the way an IP ban would.
  it "throttles contact submissions per forwarded visitor IP, isolating distinct visitors" do
    5.times do
      post "/api/contact", headers: { "X-Kona-Client-IP" => "9.9.9.9" }
      expect(response).not_to have_http_status(:too_many_requests)
    end

    post "/api/contact", headers: { "X-Kona-Client-IP" => "9.9.9.9" }
    expect(response).to have_http_status(:too_many_requests)
    expect(response.body).to eq("429 Too Many Requests\n")

    # A different visitor (same shared egress, different forwarded IP) keeps its own budget.
    post "/api/contact", headers: { "X-Kona-Client-IP" => "8.8.8.8" }
    expect(response).not_to have_http_status(:too_many_requests)
  end
end
