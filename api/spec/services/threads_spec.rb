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

    # ⚠️ The callback is a request with a 20-second rack-timeout. A Meta that hangs must give the
    # message of the page and not a 500.
    it "gives each call a timeout" do
      stub_flow

      described_class.new.connect!("a-code", redirect_uri: redirect_uri)

      expect(HTTParty).to have_received(:post).with(anything, hash_including(timeout: described_class::REQUEST_TIMEOUT))
      expect(HTTParty).to have_received(:get).with(anything, hash_including(timeout: described_class::REQUEST_TIMEOUT)).twice
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

    # ⚠️ An expired token cannot be renewed, thus a call would only record a failure. The answer
    # names the state, and it is not the same as "no account": the job writes a warning for it.
    it "answers :expired once the token expired, and calls nobody" do
      connect!(issued_at: 61.days.ago)
      $redis.hset(ThreadsCredentials::REDIS_KEY, "expires_at", 1.day.ago.utc.iso8601)
      allow(HTTParty).to receive(:get)

      expect(described_class.new.refresh!).to eq(:expired)
      expect(HTTParty).not_to have_received(:get)
    end

    it "gives Meta a timeout" do
      connect!(issued_at: 2.days.ago)
      allow(HTTParty).to receive(:get).and_return(http_response({ access_token: "a-renewed-token", expires_in: 60.days.to_i }))

      described_class.new.refresh!

      expect(HTTParty).to have_received(:get).with(anything, hash_including(timeout: described_class::REQUEST_TIMEOUT))
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

  # ⚠️ An expired token stays in the store, thus `connected?` stays true. `expired?` and `usable?`
  # are what show the difference to the card and to the Social media page.
  describe "#expired? and #usable?" do
    it "is usable while the token is inside its window" do
      connect!

      service = described_class.new
      expect(service).to be_connected
      expect(service).not_to be_expired
      expect(service).to be_usable
    end

    it "is connected and not usable once the token expired" do
      connect!
      $redis.hset(ThreadsCredentials::REDIS_KEY, "expires_at", 1.hour.ago.utc.iso8601)

      service = described_class.new
      expect(service).to be_connected
      expect(service).to be_expired
      expect(service).not_to be_usable
    end

    it "is neither with no account" do
      service = described_class.new
      expect(service).not_to be_expired
      expect(service).not_to be_usable
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

  describe "#post!" do
    let(:url) { "https://example.test/a-post/" }
    let(:key) { "3kabc" }
    let(:container_key) { "threads:container:#{key}" }

    before do
      connect!
      $redis.del(container_key)
      # ⚠️ The publish waits for the status of the container. Meta answers 400 subcode 4279009 for
      # a publish that comes too early.
      allow(HTTParty).to receive(:get).and_return(http_response({ status: "FINISHED" }))
      allow(HTTParty).to receive(:post) do |endpoint, _options|
        if endpoint.end_with?("/threads")
          http_response({ id: "container-1" })
        else
          http_response({ id: "post-1" })
        end
      end
    end

    after { $redis.del(container_key) }

    def post!(**overrides)
      described_class.new.post!(**{ text: "Read this", url: url, idempotency_key: key }.merge(overrides))
    end

    it "refuses when no account is connected" do
      ThreadsCredentials.clear

      expect { post! }.to raise_error(/not connected/)
    end

    it "refuses a post with no body" do
      expect { post!(text: "  ") }.to raise_error(/empty/)
    end

    # ⚠️ Meta would refuse the container anyway, and the message here says what to do.
    it "refuses to post with an expired token, and calls Meta not at all" do
      $redis.hset(ThreadsCredentials::REDIS_KEY, "expires_at", 1.hour.ago.utc.iso8601)

      expect { post! }.to raise_error(/expired/)
      expect(HTTParty).not_to have_received(:post)
    end

    it "sends the body with no space at its ends" do
      post!(text: "  Read this\n\n")

      expect(HTTParty).to have_received(:post).with(
        a_string_ending_with("/threads"),
        hash_including(body: hash_including(text: "Read this"), timeout: described_class::REQUEST_TIMEOUT)
      )
    end

    # ⚠️ The URL is a link_attachment and it is NOT in the text, thus Meta renders its own preview
    # card and the URL uses none of the 500 characters. Mastodon is the opposite.
    it "makes a TEXT container with the link attached" do
      post!

      expect(HTTParty).to have_received(:post).with(
        "https://graph.threads.net/v1.0/12345/threads",
        hash_including(body: { media_type: "TEXT", text: "Read this", link_attachment: url })
      )
    end

    it "keeps the link out of the text" do
      post!

      expect(HTTParty).to have_received(:post).with(
        a_string_ending_with("/threads"),
        hash_including(body: hash_including(text: "Read this"))
      )
    end

    it "attaches nothing when there is no link" do
      post!(url: nil)

      expect(HTTParty).to have_received(:post).with(
        a_string_ending_with("/threads"),
        hash_including(body: { media_type: "TEXT", text: "Read this" })
      )
    end

    it "publishes the container it made, and answers with the id of the post" do
      expect(post!).to eq("post-1")

      expect(HTTParty).to have_received(:post).with(
        "https://graph.threads.net/v1.0/12345/threads_publish",
        hash_including(body: { creation_id: "container-1" })
      )
    end

    it "forgets the container after Meta published it" do
      post!

      expect($redis.get(container_key)).to be_nil
    end

    describe "when the publish fails" do
      before do
        allow(HTTParty).to receive(:post) do |endpoint, _options|
          if endpoint.end_with?("/threads")
            http_response({ id: "container-1" })
          else
            http_response({ error: { message: "not ready" } }, success: false, code: 400)
          end
        end
      end

      it "raises with the message of Meta, thus the job runs again" do
        expect { post! }.to raise_error(/not ready/)
      end

      # ⚠️ Meta gives no idempotency header. The container id stays in Redis, thus the retry
      # publishes the container that this attempt made and does not make a second post.
      it "keeps the container for the retry" do
        expect { post! }.to raise_error(/not ready/)

        expect($redis.get(container_key)).to eq("container-1")
      end

      it "makes no second container on the next attempt" do
        creates = 0
        allow(HTTParty).to receive(:post) do |endpoint, _options|
          if endpoint.end_with?("/threads")
            creates += 1
            http_response({ id: "container-1" })
          else
            http_response({ error: { message: "not ready" } }, success: false, code: 400)
          end
        end

        2.times { expect { post! }.to raise_error(/not ready/) }

        # ⚠️ One create only. The second attempt read the container out of Redis, thus a failure
        # between the two steps cannot leave a new container at each attempt.
        expect(creates).to eq(1)
      end
    end

    describe "the wait for the container" do
      # ⚠️ Meta answers 400 subcode 4279009 for a publish that comes too early, and that reads as
      # "The requested resource does not exist". An earlier version published at once, because a
      # TEXT post uploads nothing. Meta processes a TEXT container as well.
      it "reads the status before it publishes" do
        post!

        expect(HTTParty).to have_received(:get).with(
          "https://graph.threads.net/v1.0/container-1",
          hash_including(query: hash_including(fields: "status"))
        )
      end

      it "publishes a container that Meta already published" do
        allow(HTTParty).to receive(:get).and_return(http_response({ status: "PUBLISHED" }))

        expect(post!).to eq("post-1")
      end

      it "raises for a container that Meta could not process" do
        allow(HTTParty).to receive(:get).and_return(http_response({ status: "ERROR" }))

        expect { post! }.to raise_error(/could not process/)
      end

      it "raises for a container that expired" do
        allow(HTTParty).to receive(:get).and_return(http_response({ status: "EXPIRED" }))

        expect { post! }.to raise_error(/expired/)
      end

      # ⚠️ It raises and does not publish. The container id stays in Redis, thus the retry of the
      # job waits for the same container and makes no second one.
      it "raises when the container never becomes ready, and keeps it for the retry" do
        allow(HTTParty).to receive(:get).and_return(http_response({ status: "IN_PROGRESS" }))

        expect { post! }.to raise_error(/still not ready/)

        expect($redis.get(container_key)).to eq("container-1")
        expect(HTTParty).not_to have_received(:post).with(a_string_ending_with("threads_publish"), anything)
      end

      # A read that fails is not an answer, thus it counts as "not ready" and never as an error of
      # its own.
      it "treats a status that it cannot read as not ready" do
        allow(HTTParty).to receive(:get).and_return(http_response({}, success: false, code: 500))

        expect { post! }.to raise_error(/still not ready/)
      end
    end

    it "raises when Meta refuses the container" do
      allow(HTTParty).to receive(:post)
        .and_return(http_response({ error: { message: "bad token" } }, success: false, code: 401))

      expect { post! }.to raise_error(/bad token/)
    end
  end
end
