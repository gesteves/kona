require "rails_helper"

# Rack::Attack is off in the test environment, thus the other tests in the suite have no rate
# limit. These examples set it on and use the memory store for the test environment. They set the
# counters to zero around each example, thus one example does not change another one through the
# shared client IP of 127.0.0.1.
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

    # The block applies to a path, and it is not an IP ban: correct traffic from the same IP still
    # works.
    get "/up"
    expect(response).to have_http_status(:ok)
  end

  # A probe request can come through the public web proxy, on a SHARED egress IP. A block of one
  # such request must never ban that IP. If it did, the widgets of each visitor would 403 at the
  # same time. An IP-based Fail2Ban here is the problem that stopped the site.
  it "does not let a probe ban the shared proxy IP it arrives on" do
    get "/api/status" # matches the probe pattern
    expect(response).to have_http_status(:forbidden)

    # The same IP, with a correct request. It must not change.
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
      # .well-known holds correct endpoints: security.txt, did:web, and OAuth metadata. A block
      # would 403 a future endpoint with no message. Thus a probe there gets a 404 from the
      # catch-all.
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

  # The key of the throttle must be the true client (Fly-Client-IP), and not the shared transport
  # IP. Thus one client that sends too many requests cannot use the full budget of each person
  # behind the same fly proxy address.
  it "throttles per real client IP from Fly-Client-IP, isolating distinct clients" do
    21.times { get "/no-such-page", headers: { "Fly-Client-IP" => "1.1.1.1" } }
    expect(response).to have_http_status(:too_many_requests)

    # A different client, with the same transport but a different Fly-Client-IP, keeps its own
    # budget.
    get "/no-such-page", headers: { "Fly-Client-IP" => "2.2.2.2" }
    expect(response).not_to have_http_status(:too_many_requests)
  end

  # Behind Cloudflare, fly sees a Cloudflare edge node as its client. Thus Fly-Client-IP is the same
  # PoP address for each visitor. CF-Connecting-IP has the true client and must have the highest
  # importance. Without that, the throttle becomes one global counter with the PoP as its key.
  it "prefers CF-Connecting-IP over Fly-Client-IP, isolating clients behind one Cloudflare PoP" do
    21.times do
      get "/no-such-page",
          headers: { "CF-Connecting-IP" => "1.1.1.1", "Fly-Client-IP" => "172.70.0.1" }
    end
    expect(response).to have_http_status(:too_many_requests)

    # A different visitor through the SAME Cloudflare PoP keeps its own budget.
    get "/no-such-page",
        headers: { "CF-Connecting-IP" => "2.2.2.2", "Fly-Client-IP" => "172.70.0.1" }
    expect(response).not_to have_http_status(:too_many_requests)
  end

  # Traffic that reaches fly and does not go through Cloudflare has no CF-Connecting-IP. The key
  # must still be the true client. This path is in use during a DNS propagation, and on each route
  # that does not go through the Cloudflare zone.
  it "falls back to Fly-Client-IP when CF-Connecting-IP is absent" do
    21.times { get "/no-such-page", headers: { "Fly-Client-IP" => "3.3.3.3" } }
    expect(response).to have_http_status(:too_many_requests)

    get "/no-such-page", headers: { "Fly-Client-IP" => "4.4.4.4" }
    expect(response).not_to have_http_status(:too_many_requests)
  end

  # The contact form has a throttle for each TRUE visitor IP, which the web proxy sends as
  # X-Kona-Client-IP. It is not the shared proxy egress. It is a throttle, which gives a 429, and
  # never a ban. Thus it cannot stop the shared proxy IP, and an IP ban would.
  it "throttles contact submissions per forwarded visitor IP, isolating distinct visitors" do
    5.times do
      post "/api/contact", headers: { "X-Kona-Client-IP" => "9.9.9.9" }
      expect(response).not_to have_http_status(:too_many_requests)
    end

    post "/api/contact", headers: { "X-Kona-Client-IP" => "9.9.9.9" }
    expect(response).to have_http_status(:too_many_requests)
    expect(response.body).to eq("429 Too Many Requests\n")

    # A different visitor, with the same shared egress but a different forwarded IP, keeps its own
    # budget.
    post "/api/contact", headers: { "X-Kona-Client-IP" => "8.8.8.8" }
    expect(response).not_to have_http_status(:too_many_requests)
  end

  # /signin and /auth are in RACK_ATTACK_KNOWN_PREFIXES, and that is what keeps them out of the
  # throttle for unknown paths. Thus without a rule of their own, the sign-in pages have no limit at
  # the origin. client_ip is a safe key here and at no other place: these paths are on the admin
  # host, and nothing reaches that host through the shared widget-proxy egress.
  it "throttles the sign-in surface per client IP, isolating distinct clients" do
    30.times do
      get "/signin", headers: { "CF-Connecting-IP" => "5.5.5.5" }
      expect(response).not_to have_http_status(:too_many_requests)
    end

    get "/signin", headers: { "CF-Connecting-IP" => "5.5.5.5" }
    expect(response).to have_http_status(:too_many_requests)

    # ⚠️ This is a throttle, and never a ban: the other traffic of the same client does not
    # change.
    get "/up", headers: { "CF-Connecting-IP" => "5.5.5.5" }
    expect(response).to have_http_status(:ok)

    # A different client keeps its own budget.
    get "/signin", headers: { "CF-Connecting-IP" => "6.6.6.6" }
    expect(response).not_to have_http_status(:too_many_requests)
  end

  it "covers the OAuth callback under the same throttle as the sign-in page" do
    31.times { get "/auth/google_oauth2/callback", headers: { "CF-Connecting-IP" => "7.7.7.7" } }

    expect(response).to have_http_status(:too_many_requests)
  end
end
