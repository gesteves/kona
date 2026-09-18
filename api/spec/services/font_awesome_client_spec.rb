require "rails_helper"

RSpec.describe FontAwesomeClient do
  let(:key) { "font_awesome:access_token" }

  before { $redis.del(key) }
  after { $redis.del(key) }

  def response(body, success: true, code: 200)
    instance_double(HTTParty::Response, success?: success, code: code, body: body)
  end

  describe ".get_access_token" do
    it "gives the token in Redis and asks nothing" do
      $redis.setex(key, 100, "cached")
      allow(HTTParty).to receive(:post)

      expect(described_class.get_access_token("api-token")).to eq("cached")
      expect(HTTParty).not_to have_received(:post)
    end

    # ⚠️ The cache holds the token for less than its true life, for a clock difference and for a
    # request in progress.
    it "posts the API token, then keeps the access token for less than its life" do
      allow(HTTParty).to receive(:post).and_return(response({ access_token: "tok", expires_in: 3600 }.to_json))

      expect(described_class.get_access_token("api-token")).to eq("tok")
      expect(HTTParty).to have_received(:post).with(
        "#{FontAwesomeClient::FONT_AWESOME_API_URL}/token",
        headers: hash_including("Authorization" => "Bearer api-token"), timeout: FontAwesomeClient::READ_TIMEOUT
      )
      expect($redis.get(key)).to eq("tok")
      expect($redis.ttl(key)).to be_between(1, 3600 - FontAwesomeClient::TOKEN_EXPIRY_MARGIN)
    end

    it "keeps nothing for a token whose life is inside the margin" do
      allow(HTTParty).to receive(:post).and_return(response({ access_token: "tok", expires_in: 30 }.to_json))

      expect(described_class.get_access_token("api-token")).to eq("tok")
      expect($redis.exists?(key)).to be(false)
    end

    it "gives nil and reports when the service refuses" do
      allow(HTTParty).to receive(:post).and_return(response("", success: false, code: 401))
      allow(ErrorReporter).to receive(:report_upstream)

      expect(described_class.get_access_token("api-token")).to be_nil
      expect(ErrorReporter).to have_received(:report_upstream).with("HTTP 401", hash_including(status: 401))
    end

    it "gives nil and reports when the call raises" do
      allow(HTTParty).to receive(:post).and_raise(Net::OpenTimeout)
      allow(ErrorReporter).to receive(:report_upstream)

      expect(described_class.get_access_token("api-token")).to be_nil
      expect(ErrorReporter).to have_received(:report_upstream).with(kind_of(Net::OpenTimeout), hash_including(service: "FontAwesomeClient"))
    end
  end
end
