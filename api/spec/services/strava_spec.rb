require "rails_helper"

RSpec.describe Strava do
  let(:redirect_uri) { "https://admin.example.test/connected-apps/strava/callback" }

  before do
    $redis.del(StravaCredentials::REDIS_KEY, Strava::REFRESH_LOCK_KEY, Strava::SUBSCRIPTION_KEY)
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("STRAVA_CLIENT_ID").and_return("client-id")
    allow(ENV).to receive(:[]).with("STRAVA_CLIENT_SECRET").and_return("client-secret")
  end

  def http_response(body, success: true, code: 200)
    instance_double(HTTParty::Response, success?: success, code: code, body: body.to_json, request: nil)
  end

  def connect!(expires_at: 6.hours.from_now)
    StravaCredentials.store_athlete(
      athlete_id: 42, athlete_name: "Athlete",
      access_token: "an-access-token", refresh_token: "a-refresh-token", expires_at: expires_at.to_i
    )
  end

  describe ".granted_scopes?" do
    it "is true only when each scope came back" do
      expect(described_class.granted_scopes?("read,activity:read_all,activity:write,profile:write")).to be(true)
      expect(described_class.granted_scopes?("read,activity:read_all,activity:write")).to be(false)
      expect(described_class.granted_scopes?("read,activity:write,profile:write")).to be(false)
      expect(described_class.granted_scopes?(nil)).to be(false)
    end
  end

  describe "#authorization_url" do
    it "asks for each scope, with the state and the callback of the request" do
      url = described_class.new.authorization_url("the-state", redirect_uri: redirect_uri)
      query = Rack::Utils.parse_query(URI(url).query)

      expect(url).to start_with(Strava::AUTHORIZE_URL)
      expect(query).to include("client_id" => "client-id", "redirect_uri" => redirect_uri,
                               "scope" => "activity:read_all,activity:write,profile:write", "state" => "the-state")
    end

    it "gives nil without the app credentials" do
      allow(ENV).to receive(:[]).with("STRAVA_CLIENT_ID").and_return(nil)

      expect(described_class.new.authorization_url("the-state", redirect_uri: redirect_uri)).to be_nil
    end
  end

  describe "#connect!" do
    let(:token) do
      { access_token: "an-access-token", refresh_token: "a-refresh-token", expires_at: 6.hours.from_now.to_i,
        athlete: { id: 42, firstname: "Jane", lastname: "Doe" } }
    end

    it "stores the tokens and the athlete" do
      allow(HTTParty).to receive(:post).and_return(http_response(token))

      expect(described_class.new.connect!("a-code")).to be(true)

      credentials = StravaCredentials.fetch
      expect(credentials.access_token).to eq("an-access-token")
      expect(credentials.refresh_token).to eq("a-refresh-token")
      expect(credentials.athlete_name).to eq("Jane Doe")
      expect(HTTParty).to have_received(:post).with(
        Strava::TOKEN_URL,
        hash_including(body: hash_including(code: "a-code", grant_type: "authorization_code"),
                       timeout: Strava::REQUEST_TIMEOUT)
      )
    end

    it "stores nothing when Strava gives no refresh token" do
      allow(HTTParty).to receive(:post).and_return(http_response(token.except(:refresh_token)))

      expect(described_class.new.connect!("a-code")).to be(false)
      expect(StravaCredentials.connected?).to be(false)
    end

    it "stores nothing when the exchange fails" do
      allow(ErrorReporter).to receive(:report_upstream)
      allow(HTTParty).to receive(:post).and_return(http_response({ message: "Bad Request" }, success: false, code: 400))

      expect(described_class.new.connect!("a-code")).to be(false)
      expect(StravaCredentials.connected?).to be(false)
    end
  end

  describe "#update_activity!" do
    it "PUTs the fields with the stored token" do
      connect!
      allow(HTTParty).to receive(:put).and_return(http_response({ id: 1 }))

      described_class.new.update_activity!("123", name: "Morning Ride", description: "⚡️ Avg 200 W")

      expect(HTTParty).to have_received(:put).with(
        "#{Strava::API_URL}/activities/123",
        hash_including(body: { name: "Morning Ride", description: "⚡️ Avg 200 W" }.to_json,
                       headers: hash_including("Authorization" => "Bearer an-access-token"))
      )
    end

    it "raises on a failure, thus the job does the work again" do
      connect!
      allow(HTTParty).to receive(:put).and_return(http_response({}, success: false, code: 500))

      expect { described_class.new.update_activity!("123", description: "x") }.to raise_error(ApplicationService::HttpError)
    end

    it "raises with no connected athlete" do
      expect { described_class.new.update_activity!("123", description: "x") }.to raise_error(/No Strava access token/)
    end
  end

  describe "#update_athlete_ftp!" do
    it "PUTs the FTP with the stored token and gives the FTP of the response" do
      connect!
      allow(HTTParty).to receive(:put).and_return(http_response({ id: 42, ftp: 265 }))

      expect(described_class.new.update_athlete_ftp!(265)).to eq(265)
      expect(HTTParty).to have_received(:put).with(
        "#{Strava::API_URL}/athlete",
        hash_including(body: { ftp: 265 }, headers: hash_including("Authorization" => "Bearer an-access-token"))
      )
    end

    it "raises on a failure, thus the job does the work again" do
      connect!
      allow(HTTParty).to receive(:put).and_return(http_response({}, success: false, code: 500))

      expect { described_class.new.update_athlete_ftp!(265) }.to raise_error(ApplicationService::HttpError)
    end
  end

  describe "#update_athlete_weight!" do
    it "PUTs the weight with the stored token" do
      connect!
      allow(HTTParty).to receive(:put).and_return(http_response({ id: 42 }))

      described_class.new.update_athlete_weight!(72.4)

      expect(HTTParty).to have_received(:put).with(
        "#{Strava::API_URL}/athlete",
        hash_including(body: { weight: 72.4 }, headers: hash_including("Authorization" => "Bearer an-access-token"))
      )
    end

    it "raises on a failure, thus the job does the work again" do
      connect!
      allow(HTTParty).to receive(:put).and_return(http_response({}, success: false, code: 500))

      expect { described_class.new.update_athlete_weight!(72.4) }.to raise_error(ApplicationService::HttpError)
    end
  end

  describe "#activity" do
    it "gives the name and the description only" do
      connect!
      allow(HTTParty).to receive(:get).and_return(http_response({ name: "Ride", description: "Hello", distance: 1000 }))

      expect(described_class.new.activity("123")).to eq(name: "Ride", description: "Hello")
    end
  end

  describe "the token refresh" do
    let(:refreshed) { { access_token: "a-new-token", refresh_token: "a-new-refresh-token", expires_at: 6.hours.from_now.to_i } }

    before { allow(HTTParty).to receive(:get).and_return(http_response({ name: "Ride", description: nil })) }

    it "refreshes an access token that is about to expire, and stores BOTH new tokens" do
      connect!(expires_at: 1.minute.from_now)
      allow(HTTParty).to receive(:post).and_return(http_response(refreshed))

      described_class.new.activity("123")

      credentials = StravaCredentials.fetch
      expect(credentials.access_token).to eq("a-new-token")
      expect(credentials.refresh_token).to eq("a-new-refresh-token")
      expect(HTTParty).to have_received(:post).with(
        Strava::TOKEN_URL, hash_including(body: hash_including(grant_type: "refresh_token", refresh_token: "a-refresh-token"))
      )
      expect(HTTParty).to have_received(:get).with(anything, hash_including(headers: { "Authorization" => "Bearer a-new-token" }))
    end

    it "makes no refresh for a token that is still good" do
      connect!
      allow(HTTParty).to receive(:post)

      described_class.new.activity("123")

      expect(HTTParty).not_to have_received(:post)
    end

    it "records a refused refresh, thus the card says so" do
      connect!(expires_at: 1.minute.ago)
      allow(ErrorReporter).to receive(:report_upstream)
      allow(HTTParty).to receive(:post).and_return(http_response({ message: "Bad Request" }, success: false, code: 400))

      expect { described_class.new.activity("123") }.to raise_error(/No Strava access token/)
      expect(StravaCredentials.fetch.refresh_error).to include(code: 400)
    end

    it "waits for the token of a refresh in progress, and does not POST a second refresh" do
      connect!(expires_at: 1.minute.ago)
      $redis.set(Strava::REFRESH_LOCK_KEY, "1")
      allow(HTTParty).to receive(:post)
      service = described_class.new
      allow(service).to receive(:sleep) { StravaCredentials.store_tokens(**refreshed) }

      service.activity("123")

      expect(HTTParty).not_to have_received(:post)
      expect(HTTParty).to have_received(:get).with(anything, hash_including(headers: { "Authorization" => "Bearer a-new-token" }))
    end
  end

  describe "#subscribe!" do
    let(:callback_url) { "https://api.example.test/webhooks/strava" }

    before { allow(ENV).to receive(:[]).with("STRAVA_WEBHOOK_VERIFY_TOKEN").and_return("the-verify-token") }

    it "makes the subscription and stores its id" do
      allow(HTTParty).to receive(:get).and_return(http_response([]))
      allow(HTTParty).to receive(:post).and_return(http_response({ id: 77 }))

      expect(described_class.new.subscribe!(callback_url)).to eq("77")
      expect(described_class.subscription_id).to eq("77")
      expect(HTTParty).to have_received(:post).with(
        "#{Strava::API_URL}/push_subscriptions",
        hash_including(body: hash_including(callback_url: callback_url, verify_token: "the-verify-token"))
      )
    end

    # ⚠️ Strava permits one subscription for each app. After a Redis flush, the task must find it.
    it "stores the id of the subscription that exists, and makes no second one" do
      allow(HTTParty).to receive(:get).and_return(http_response([ { id: 77, callback_url: callback_url } ]))
      allow(HTTParty).to receive(:post)

      expect(described_class.new.subscribe!(callback_url)).to eq("77")
      expect(HTTParty).not_to have_received(:post)
    end

    it "refuses to replace a subscription for another URL" do
      allow(HTTParty).to receive(:get).and_return(http_response([ { id: 77, callback_url: "https://old.example.test/hook" } ]))

      expect { described_class.new.subscribe!(callback_url) }.to raise_error(/already uses/)
      expect(described_class.subscription_id).to be_nil
    end
  end

  describe "#disconnect!" do
    it "revokes the access and clears the store" do
      connect!
      allow(HTTParty).to receive(:post).and_return(http_response({}))

      described_class.new.disconnect!

      expect(HTTParty).to have_received(:post).with(Strava::DEAUTHORIZE_URL, hash_including(body: { access_token: "an-access-token" }))
      expect(StravaCredentials.connected?).to be(false)
    end

    it "clears the store when Strava is away" do
      connect!
      allow(ErrorReporter).to receive(:report_upstream)
      allow(HTTParty).to receive(:post).and_raise(Net::OpenTimeout)

      described_class.new.disconnect!

      expect(StravaCredentials.connected?).to be(false)
    end
  end
end
