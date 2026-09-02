require "rails_helper"

RSpec.describe PublicAddress do
  before { allow(described_class).to receive(:addresses).and_call_original }

  it "refuses each private, loopback, link-local, and reserved address" do
    %w[
      http://127.0.0.1/ http://10.1.2.3/ http://172.16.0.1/ http://192.168.1.1/ http://169.254.169.254/
      http://100.64.0.1/ http://0.0.0.0/ http://[::1]/ http://[fdaa:0:1::3]/ http://[fe80::1]/
      http://[::ffff:10.0.0.1]/
    ].each do |url|
      expect(described_class.public_url?(url)).to be(false), url
    end
  end

  it "accepts a public address" do
    expect(described_class.public_url?("https://203.0.113.9/x")).to be(true)
    expect(described_class.public_url?("https://[2001:db8::1]/x")).to be(true)
  end

  it "refuses a private host name, a port that is not a web port, and a scheme that is not http" do
    expect(described_class.public_url?("http://kona-redis.internal/")).to be(false)
    expect(described_class.public_url?("http://localhost/")).to be(false)
    expect(described_class.public_url?("http://printer.local/")).to be(false)
    expect(described_class.public_url?("https://203.0.113.9:6379/")).to be(false)
    expect(described_class.public_url?("ftp://203.0.113.9/")).to be(false)
    expect(described_class.public_url?("not a url")).to be(false)
  end

  it "resolves a name and refuses one with any private address" do
    allow(Resolv).to receive(:getaddresses).with("mixed.example").and_return([ "203.0.113.9", "10.0.0.5" ])
    allow(Resolv).to receive(:getaddresses).with("public.example").and_return([ "203.0.113.9" ])
    allow(Resolv).to receive(:getaddresses).with("nowhere.example").and_return([])

    expect(described_class.public_url?("https://mixed.example/")).to be(false)
    expect(described_class.public_url?("https://public.example/")).to be(true)
    expect(described_class.public_url?("https://nowhere.example/")).to be(false)
  end
end
