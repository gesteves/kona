require "rails_helper"

RSpec.describe Whoop do
  subject(:service) { described_class.new }

  let(:access_token_key) { "whoop:cid:access_token" }
  let(:refresh_token_key) { "whoop:cid:refresh_token" }
  let(:lock_key) { "whoop:cid:refresh_lock" }
  let(:error_key) { "whoop:cid:refresh_error" }

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("WHOOP_CLIENT_ID").and_return("cid")
    allow(ENV).to receive(:[]).with("WHOOP_CLIENT_SECRET").and_return("secret")
    allow(ENV).to receive(:[]).with("WHOOP_REDIRECT_URI").and_return("https://example.com/whoop/callback")

    allow($redis).to receive(:get).and_return(nil)
    allow($redis).to receive(:set).and_return(true)
    allow($redis).to receive(:setex)
    allow($redis).to receive(:del)
    allow(HTTParty).to receive(:post)
  end

  def get_access_token
    service.send(:get_access_token)
  end

  # Matches a Redis value that holds the given token, encrypted.
  def sealed(token)
    satisfy("an encrypted #{token}") { |value| value != token && WhoopCredentials.open(value) == token }
  end

  describe "#connected?" do
    it "is true when a refresh token is stored" do
      allow($redis).to receive(:exists?).with(refresh_token_key).and_return(true)

      expect(service).to be_connected
    end

    it "is false when no refresh token is stored" do
      allow($redis).to receive(:exists?).with(refresh_token_key).and_return(false)

      expect(service).not_to be_connected
    end

    # With no credentials, the key name is not correct, because the client id is nil. Thus the code
    # returns early and does not read Redis.
    it "is false — without touching Redis — when the credentials are missing" do
      allow(ENV).to receive(:[]).with("WHOOP_CLIENT_SECRET").and_return(nil)
      expect($redis).not_to receive(:exists?)

      expect(service).not_to be_connected
    end
  end

  describe "#account_email" do
    let(:email_key) { "whoop:cid:account_email" }

    it "returns the stored address" do
      allow($redis).to receive(:get).with(email_key).and_return("athlete@example.com")

      expect(service.account_email).to eq("athlete@example.com")
    end

    # ⚠️ The Connected apps page reads this on each load. A fetch here would put an upstream failure
    # in the path of the admin navigation.
    it "never calls Whoop" do
      allow(HTTParty).to receive(:get)

      service.account_email

      expect(HTTParty).not_to have_received(:get)
    end
  end

  describe "#store_account_email!" do
    let(:email_key) { "whoop:cid:account_email" }

    before { allow($redis).to receive(:get).with(access_token_key).and_return("cached-token") }

    it "stores the address from the profile" do
      allow(HTTParty).to receive(:get).and_return(
        instance_double(HTTParty::Response, success?: true, code: 200,
                        body: { user_id: 1, email: "athlete@example.com" }.to_json, request: nil)
      )

      expect(service.store_account_email!).to eq("athlete@example.com")
      expect($redis).to have_received(:set).with(email_key, "athlete@example.com")
    end

    # ⚠️ The address is a label for the admin. A Whoop that is not available must never stop an
    # authorization or a token refresh.
    it "fails soft when the profile fetch does not work" do
      allow(HTTParty).to receive(:get).and_raise(SocketError)

      expect { service.store_account_email! }.not_to raise_error
      expect(service.store_account_email!).to be_nil
    end
  end

  describe "#disconnect!" do
    # ⚠️ The cached user_id must go away with the tokens. Webhooks::WhoopController compares each
    # payload with it, thus a copy that stays would continue to accept a webhook for an account with
    # no tokens.
    it "deletes both tokens, the cached user id, the refresh lock, the failure, and the label" do
      expect($redis).to receive(:del).with(
        access_token_key, refresh_token_key, "whoop:cid:user_id", lock_key, error_key,
        "whoop:cid:account_email"
      )

      service.disconnect!
    end
  end

  describe "#get_access_token" do
    it "returns the cached access token without refreshing" do
      allow($redis).to receive(:get).with(access_token_key).and_return("cached-token")

      expect(get_access_token).to eq("cached-token")
      expect(HTTParty).not_to have_received(:post)
    end

    context "when the token must be refreshed" do
      let(:token_response) do
        instance_double(
          HTTParty::Response,
          success?: true,
          body: { access_token: "fresh-token", refresh_token: "rotated-refresh", expires_in: 3600 }.to_json
        )
      end

      before do
        allow($redis).to receive(:get).with(refresh_token_key).and_return("current-refresh")
        allow(HTTParty).to receive(:post).and_return(token_response)
      end

      it "sends the stored refresh token, decrypted, and reads one stored before the encryption as it is" do
        allow($redis).to receive(:get).with(refresh_token_key).and_return(WhoopCredentials.seal("current-refresh"))
        get_access_token
        expect(HTTParty).to have_received(:post).with(anything, hash_including(body: hash_including("refresh_token" => "current-refresh")))

        allow($redis).to receive(:get).with(refresh_token_key).and_return("plain-refresh")
        get_access_token
        expect(HTTParty).to have_received(:post).with(anything, hash_including(body: hash_including("refresh_token" => "plain-refresh")))
      end

      it "takes the lock, refreshes, stores the rotated tokens, and releases the lock" do
        expect(get_access_token).to eq("fresh-token")

        expect($redis).to have_received(:set).with(lock_key, "1", nx: true, ex: kind_of(Integer))
        expect($redis).to have_received(:setex).with(access_token_key, 3540, sealed("fresh-token"))
        expect($redis).to have_received(:set).with(refresh_token_key, sealed("rotated-refresh"))
        expect($redis).to have_received(:del).with(lock_key)
      end

      it "re-checks the cache inside the lock instead of re-POSTing a rotated refresh token" do
        # The check before the lock finds nothing. The check after the lock finds the token that
        # another refresh at the same time stored.
        allow($redis).to receive(:get).with(access_token_key).and_return(nil, "already-refreshed")

        expect(get_access_token).to eq("already-refreshed")
        expect(HTTParty).not_to have_received(:post)
        expect($redis).to have_received(:del).with(lock_key)
      end

      it "releases the lock even when the refresh fails" do
        allow(HTTParty).to receive(:post).and_return(instance_double(HTTParty::Response, success?: false, code: 401, body: ""))

        expect(get_access_token).to be_nil
        expect($redis).to have_received(:del).with(lock_key)
      end
    end

    context "when another request holds the refresh lock" do
      before do
        allow($redis).to receive(:set).with(lock_key, "1", nx: true, ex: kind_of(Integer)).and_return(false)
        allow(service).to receive(:sleep) # poll without slowing the suite
      end

      it "waits for the lock holder's token instead of racing the refresh" do
        allow($redis).to receive(:get).with(access_token_key).and_return(nil, nil, "winner-token")

        expect(get_access_token).to eq("winner-token")
        expect(HTTParty).not_to have_received(:post)
      end

      it "gives up quietly when no token appears in time" do
        expect(get_access_token).to be_nil
        expect(HTTParty).not_to have_received(:post)
        expect($redis).not_to have_received(:del) # never held the lock, must not clear it
      end
    end
  end

  describe "#refresh_tokens!" do
    let(:token_response) do
      instance_double(
        HTTParty::Response,
        success?: true,
        body: { access_token: "fresh-token", refresh_token: "rotated-refresh", expires_in: 3600 }.to_json
      )
    end

    before do
      allow($redis).to receive(:get).with(refresh_token_key).and_return("current-refresh")
      allow(HTTParty).to receive(:post).and_return(token_response)
    end

    # This is the purpose of the scheduled refresh: the access token is still good at a normal run,
    # thus with the cache the refresh token would never rotate.
    it "refreshes even when the cached access token is still valid" do
      allow($redis).to receive(:get).with(access_token_key).and_return("cached-token")

      expect(service.refresh_tokens!).to eq("fresh-token")
      expect(HTTParty).to have_received(:post)
      expect($redis).to have_received(:set).with(refresh_token_key, sealed("rotated-refresh"))
      expect($redis).to have_received(:del).with(lock_key)
    end

    # ⚠️ force: does not do the cache check, and it always takes the lock. A refresh at the same time
    # as a refresh in a request is the rotation race that the lock stops.
    it "still waits for the lock holder rather than racing an in-request refresh" do
      allow($redis).to receive(:set).with(lock_key, "1", nx: true, ex: kind_of(Integer)).and_return(false)
      allow($redis).to receive(:get).with(access_token_key).and_return(nil, "winner-token")
      allow(service).to receive(:sleep)

      expect(service.refresh_tokens!).to eq("winner-token")
      expect(HTTParty).not_to have_received(:post)
    end
  end

  describe "recording a rejected refresh" do
    let(:code) { 401 }
    let(:refresh_failure) { instance_double(HTTParty::Response, success?: false, code: code, body: "") }

    before do
      allow($redis).to receive(:get).with(refresh_token_key).and_return("current-refresh")
      allow(HTTParty).to receive(:post).and_return(refresh_failure)
    end

    context "when Whoop rejects the refresh token" do
      let(:code) { 401 }

      it "records the failure so the admin page can surface it" do
        expect(get_access_token).to be_nil
        expect($redis).to have_received(:set).with(error_key, a_string_including('"code":401'))
      end
    end

    # ⚠️ A 5xx means that Whoop is down, and not that the token is dead. A mark for it would tell the
    # owner to authorize again while the stored credentials are good.
    context "when Whoop itself is failing" do
      let(:code) { 503 }

      it "does not record a failure" do
        expect(get_access_token).to be_nil
        expect($redis).not_to have_received(:set).with(error_key, anything)
      end
    end

    context "when the refresh raises instead of returning a response" do
      let(:code) { 500 }

      it "does not record a failure" do
        allow(HTTParty).to receive(:post).and_raise(Errno::ECONNREFUSED)

        expect(get_access_token).to be_nil
        expect($redis).not_to have_received(:set).with(error_key, anything)
      end
    end

    it "clears a recorded failure once a refresh succeeds" do
      allow(HTTParty).to receive(:post).and_return(
        instance_double(
          HTTParty::Response,
          success?: true,
          body: { access_token: "fresh-token", refresh_token: "rotated-refresh", expires_in: 3600 }.to_json
        )
      )

      expect(get_access_token).to eq("fresh-token")
      expect($redis).to have_received(:del).with(error_key)
    end
  end

  describe "#refresh_error" do
    it "returns the recorded failure" do
      allow($redis).to receive(:get).with(error_key).and_return({ code: 401, at: "2026-08-18T22:00:00Z" }.to_json)

      expect(service.refresh_error).to eq(code: 401, at: "2026-08-18T22:00:00Z")
    end

    it "is nil when the last refresh succeeded" do
      allow($redis).to receive(:get).with(error_key).and_return(nil)

      expect(service.refresh_error).to be_nil
    end
  end

  describe "webhook-path fetchers" do
    before do
      allow($redis).to receive(:get).with(access_token_key).and_return("token")
    end

    def http_error(status)
      ApplicationService::HttpError.new(status, "", "url")
    end

    describe "#user_id" do
      it "fetches the profile's user_id and caches it" do
        allow(service).to receive(:get_json!).and_return({ user_id: 12345 })
        expect($redis).to receive(:setex).with("whoop:cid:user_id", 1.day, "12345")

        expect(service.user_id).to eq(12345)
      end

      it "raises without an access token" do
        allow($redis).to receive(:get).with(access_token_key).and_return(nil)
        allow($redis).to receive(:get).with(refresh_token_key).and_return(nil)

        expect { service.user_id }.to raise_error(/No Whoop access token/)
      end
    end

    describe "#get_workout" do
      it "normalizes a SCORED workout, mapping the sport name" do
        allow(service).to receive(:get_json!).and_return(
          {
            id: "w-uuid",
            sport_name: "weightlifting",
            start: "2026-07-09T13:30:00.000Z",
            score_state: "SCORED",
            score: { strain: 8.4 }
          }
        )

        workout = service.get_workout("w-uuid")

        expect(workout).to include(id: "w-uuid", activity_type: "Strength", strain: 8.4)
        expect(workout[:start_time]).to eq(Time.iso8601("2026-07-09T13:30:00.000Z"))
      end

      it "maps unmapped sports to Other and spin to Cycling" do
        base = { id: "w", start: "2026-07-09T13:30:00Z", score_state: "SCORED", score: { strain: 1 } }

        allow(service).to receive(:get_json!).and_return(base.merge(sport_name: "Pickleball"))
        expect(service.get_workout("w")[:activity_type]).to eq("Other")

        allow(service).to receive(:get_json!).and_return(base.merge(sport_name: "Spin"))
        expect(service.get_workout("w")[:activity_type]).to eq("Cycling")
      end

      it "returns nil on 404 and for unscored workouts" do
        allow(service).to receive(:get_json!).and_raise(http_error(404))
        expect(service.get_workout("gone")).to be_nil

        allow(service).to receive(:get_json!).and_return({ id: "w", score_state: "PENDING_SCORE", score: nil })
        expect(service.get_workout("w")).to be_nil
      end

      it "propagates other HTTP errors" do
        allow(service).to receive(:get_json!).and_raise(http_error(500))
        expect { service.get_workout("w") }.to raise_error(ApplicationService::HttpError)
      end
    end

    describe "#get_sleep" do
      it "returns the raw SCORED sleep and nil otherwise" do
        sleep_data = { id: "s", score_state: "SCORED", nap: false }
        allow(service).to receive(:get_json!).and_return(sleep_data)
        expect(service.get_sleep("s")).to eq(sleep_data)

        allow(service).to receive(:get_json!).and_return({ id: "s", score_state: "PENDING_SCORE" })
        expect(service.get_sleep("s")).to be_nil

        allow(service).to receive(:get_json!).and_raise(http_error(404))
        expect(service.get_sleep("s")).to be_nil
      end
    end

    describe "#get_recovery_for_cycle" do
      it "returns the raw SCORED recovery and nil otherwise" do
        recovery = { cycle_id: 42, score_state: "SCORED", score: { recovery_score: 82 } }
        allow(service).to receive(:get_json!).and_return(recovery)
        expect(service.get_recovery_for_cycle(42)).to eq(recovery)

        allow(service).to receive(:get_json!).and_raise(http_error(404))
        expect(service.get_recovery_for_cycle(42)).to be_nil
      end
    end

    describe "#raw_cycles" do
      it "queries the buffered UTC window and follows pagination" do
        page_one = { records: [ { id: 1 } ], next_token: "page2" }
        page_two = { records: [ { id: 2 } ], next_token: nil }
        allow(service).to receive(:get_json!).and_return(page_one, page_two)

        cycles = service.raw_cycles("2026-07-08", "2026-07-10")

        expect(cycles.map { |c| c[:id] }).to eq([ 1, 2 ])
        expect(service).to have_received(:get_json!).with(
          "#{Whoop::WHOOP_API_URL}/cycle",
          hash_including(query: hash_including(start: "2026-07-08T00:00:00.000Z", end: "2026-07-10T23:59:59.999Z"))
        ).twice
        expect(service).to have_received(:get_json!).with(
          "#{Whoop::WHOOP_API_URL}/cycle",
          hash_including(query: hash_including(nextToken: "page2"))
        ).once
      end
    end
  end
end
