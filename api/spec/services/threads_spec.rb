require "rails_helper"

RSpec.describe Threads do
  let(:redirect_uri) { "https://admin.example.test/connected-apps/threads/callback" }

  before do
    $redis.del(ThreadsCredentials::REDIS_KEY)
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("THREADS_APP_ID").and_return("app-id")
    allow(ENV).to receive(:[]).with("THREADS_APP_SECRET").and_return("app-secret")
  end

  after { $redis.del(ThreadsCredentials::REDIS_KEY) }

  def http_response(body, success: true, code: 200)
    instance_double(HTTParty::Response, success?: success, code: code, body: body.to_json, request: nil)
  end

  def connect!(issued_at: Time.current)
    ThreadsCredentials.store_account(
      access_token: "a-long-lived-token", expires_in: 60.days.to_i,
      user_id: "12345", username: "me"
    )
    $redis.hset(ThreadsCredentials::REDIS_KEY, "issued_at", issued_at.utc.iso8601)
  end

  describe "#valid_credentials?" do
    it "is true with both app credentials" do
      expect(described_class.new).to be_valid_credentials
    end

    it "is false without them" do
      allow(ENV).to receive(:[]).with("THREADS_APP_SECRET").and_return(nil)

      expect(described_class.new).not_to be_valid_credentials
    end
  end

  describe "#authorization_url" do
    it "points at Threads and carries the state and the callback of the caller" do
      url = described_class.new.authorization_url("a-state", redirect_uri: redirect_uri)

      expect(url).to start_with("https://threads.net/oauth/authorize?")
      expect(url).to include("client_id=app-id")
      expect(url).to include("response_type=code")
      expect(url).to include("state=a-state")
      expect(url).to include("scope=#{CGI.escape('threads_basic,threads_content_publish')}")
      expect(url).to include(CGI.escape(redirect_uri))
    end

    it "is nil with no app credentials" do
      allow(ENV).to receive(:[]).with("THREADS_APP_ID").and_return(nil)

      expect(described_class.new.authorization_url("a-state", redirect_uri: redirect_uri)).to be_nil
    end
  end

  describe "#connect!" do
    # The three calls of the flow: the code gives a 1-hour token, the exchange gives the 60-day
    # token, and /me gives the name.
    def stub_flow(profile: { id: "12345", username: "me" })
      allow(HTTParty).to receive(:post).and_return(http_response({ access_token: "short-lived", user_id: "12345" }))
      allow(HTTParty).to receive(:get) do |url, _options|
        if url.include?("/me")
          http_response(profile)
        else
          http_response({ access_token: "a-long-lived-token", expires_in: 60.days.to_i })
        end
      end
    end

    it "stores the long-lived token and the account" do
      stub_flow

      expect(described_class.new.connect!("a-code", redirect_uri: redirect_uri)).to be(true)

      credentials = ThreadsCredentials.fetch
      expect(credentials.access_token).to eq("a-long-lived-token")
      expect(credentials.username).to eq("me")
      expect(credentials.expires_at).to be_within(1.minute).of(60.days.from_now)
    end

    it "exchanges the code with the same redirect URI that the authorization used" do
      stub_flow

      described_class.new.connect!("a-code", redirect_uri: redirect_uri)

      expect(HTTParty).to have_received(:post).with(
        "https://graph.threads.net/oauth/access_token",
        hash_including(body: hash_including(code: "a-code", redirect_uri: redirect_uri, grant_type: "authorization_code"))
      )
    end

    # ⚠️ The short-lived token lasts an hour. To store it would give a connection that dies the
    # same day.
    it "exchanges the short-lived token for the 60-day one" do
      stub_flow

      described_class.new.connect!("a-code", redirect_uri: redirect_uri)

      expect(HTTParty).to have_received(:get).with(
        "https://graph.threads.net/access_token",
        hash_including(query: hash_including(grant_type: "th_exchange_token", access_token: "short-lived"))
      )
    end

    it "stores nothing when the code is refused" do
      allow(HTTParty).to receive(:post).and_return(http_response({ error: "invalid" }, success: false, code: 400))

      expect(described_class.new.connect!("a-code", redirect_uri: redirect_uri)).to be(false)
      expect(ThreadsCredentials.connected?).to be(false)
    end

    # ⚠️ A token that cannot read its own account is not a connection.
    it "stores nothing when the token cannot read the account" do
      stub_flow(profile: { error: "unauthorized" })

      expect(described_class.new.connect!("a-code", redirect_uri: redirect_uri)).to be(false)
      expect(ThreadsCredentials.connected?).to be(false)
    end

    it "does nothing with no app credentials" do
      allow(ENV).to receive(:[]).with("THREADS_APP_ID").and_return(nil)
      allow(HTTParty).to receive(:post)

      expect(described_class.new.connect!("a-code", redirect_uri: redirect_uri)).to be(false)
      expect(HTTParty).not_to have_received(:post)
    end
  end

  describe "#refresh!" do
    it "stores the new token and moves the expiry out" do
      connect!(issued_at: 2.days.ago)
      allow(HTTParty).to receive(:get).and_return(http_response({ access_token: "a-renewed-token", expires_in: 60.days.to_i }))

      expect(described_class.new.refresh!).to eq(:refreshed)

      credentials = ThreadsCredentials.fetch
      expect(credentials.access_token).to eq("a-renewed-token")
      expect(credentials.expires_at).to be_within(1.minute).of(60.days.from_now)
      expect(HTTParty).to have_received(:get).with(
        "https://graph.threads.net/refresh_access_token",
        hash_including(query: hash_including(grant_type: "th_refresh_token", access_token: "a-long-lived-token"))
      )
    end

    # ⚠️ Meta refuses a refresh before the token is 24 hours old. That is "not yet", and the card
    # must not say "Needs attention" for a connection that a person made minutes ago.
    it "waits, without calling Meta, while the token is too new" do
      connect!
      allow(HTTParty).to receive(:get)

      expect(described_class.new.refresh!).to eq(:too_soon)
      expect(HTTParty).not_to have_received(:get)
      expect(ThreadsCredentials.fetch.refresh_error).to be_nil
    end

    it "does nothing with no account connected" do
      allow(HTTParty).to receive(:get)

      expect(described_class.new.refresh!).to eq(:skipped)
      expect(HTTParty).not_to have_received(:get)
    end

    # An expired token cannot be renewed, thus a call would only record a failure that the card
    # already shows.
    it "does nothing once the token expired" do
      connect!(issued_at: 61.days.ago)
      $redis.hset(ThreadsCredentials::REDIS_KEY, "expires_at", 1.day.ago.utc.iso8601)
      allow(HTTParty).to receive(:get)

      expect(described_class.new.refresh!).to eq(:skipped)
      expect(HTTParty).not_to have_received(:get)
    end

    it "records a 4xx, so the card can say the connection needs attention" do
      connect!(issued_at: 2.days.ago)
      allow(HTTParty).to receive(:get).and_return(http_response({ error: "expired" }, success: false, code: 400))

      expect(described_class.new.refresh!).to eq(:failed)
      expect(ThreadsCredentials.fetch.refresh_error).to include(code: 400)
      expect(ThreadsCredentials.connected?).to be(true)
    end

    # ⚠️ A 5xx means Meta is away. The next run recovers, and the owner needs no message.
    it "keeps quiet about a 5xx" do
      connect!(issued_at: 2.days.ago)
      allow(HTTParty).to receive(:get).and_return(http_response({}, success: false, code: 503))

      expect(described_class.new.refresh!).to eq(:failed)
      expect(ThreadsCredentials.fetch.refresh_error).to be_nil
    end

    it "keeps the stored token when the call raises" do
      connect!(issued_at: 2.days.ago)
      allow(HTTParty).to receive(:get).and_raise(SocketError)

      expect(described_class.new.refresh!).to eq(:failed)
      expect(ThreadsCredentials.fetch.access_token).to eq("a-long-lived-token")
    end
  end

  describe "#disconnect!" do
    # ⚠️ Meta gives no revoke endpoint, thus this is a local removal only.
    it "forgets the account without calling Meta" do
      connect!
      allow(HTTParty).to receive(:post)
      allow(HTTParty).to receive(:get)

      described_class.new.disconnect!

      expect(ThreadsCredentials.connected?).to be(false)
      expect(HTTParty).not_to have_received(:post)
      expect(HTTParty).not_to have_received(:get)
    end
  end
end
