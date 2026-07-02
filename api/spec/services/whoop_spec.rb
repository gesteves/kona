require "rails_helper"

RSpec.describe Whoop do
  subject(:service) { described_class.new }

  let(:access_token_key) { "whoop:cid:access_token" }
  let(:refresh_token_key) { "whoop:cid:refresh_token" }
  let(:lock_key) { "whoop:cid:refresh_lock" }

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

      it "takes the lock, refreshes, stores the rotated tokens, and releases the lock" do
        expect(get_access_token).to eq("fresh-token")

        expect($redis).to have_received(:set).with(lock_key, "1", nx: true, ex: kind_of(Integer))
        expect($redis).to have_received(:setex).with(access_token_key, 3540, "fresh-token")
        expect($redis).to have_received(:set).with(refresh_token_key, "rotated-refresh")
        expect($redis).to have_received(:del).with(lock_key)
      end

      it "re-checks the cache inside the lock instead of re-POSTing a rotated refresh token" do
        # Pre-lock check misses; post-lock check finds the token a concurrent refresh stored.
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
end
