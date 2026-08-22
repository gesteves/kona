require "rails_helper"

RSpec.describe GoogleGeocoder do
  let(:body) do
    { results: [ { geometry: { location: { lat: 37.7749, lng: -122.4194 } } } ] }.to_json
  end

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("GOOGLE_API_KEY").and_return("google-key")

    # The cache always gives a miss. The code records each write, and each write does nothing.
    allow($redis).to receive(:get).and_return(nil)
    allow($redis).to receive(:setex)

    allow(HTTParty).to receive(:get).and_return(instance_double(HTTParty::Response, success?: true, body: body))
  end

  it "geocodes an address into coordinates" do
    expect(described_class.new("1 Ferry Building, San Francisco").coordinates).to eq([ 37.7749, -122.4194 ])

    expect(HTTParty).to have_received(:get).with(
      a_string_matching(%r{/geocode/json}),
      hash_including(query: hash_including(address: "1 Ferry Building, San Francisco", key: "google-key"))
    )
  end

  it "trims what it's given" do
    described_class.new("  Kona  ").coordinates

    expect(HTTParty).to have_received(:get).with(anything, hash_including(query: hash_including(address: "Kona")))
  end

  it "asks for nothing when the address is blank" do
    expect(described_class.new("   ").coordinates).to be_nil
    expect(described_class.new(nil).coordinates).to be_nil

    expect(HTTParty).not_to have_received(:get)
  end

  it "asks for nothing without an API key" do
    allow(ENV).to receive(:[]).with("GOOGLE_API_KEY").and_return(nil)

    expect(described_class.new("Kona").coordinates).to be_nil
    expect(HTTParty).not_to have_received(:get)
  end

  it "returns nothing when the address resolves to nothing" do
    allow(HTTParty).to receive(:get)
      .and_return(instance_double(HTTParty::Response, success?: true, body: { results: [] }.to_json))

    expect(described_class.new("asdfgh").coordinates).to be_nil
  end

  it "returns nothing when the lookup fails" do
    allow(HTTParty).to receive(:get).and_return(
      instance_double(HTTParty::Response, success?: false, code: 500, body: "", request: nil)
    )

    expect(described_class.new("Kona").coordinates).to be_nil
  end

  # ⚠️ The app stores this pair as the current location, and Location.store checks nothing.
  it "refuses coordinates outside the valid ranges" do
    allow(HTTParty).to receive(:get).and_return(
      instance_double(HTTParty::Response, success?: true,
                      body: { results: [ { geometry: { location: { lat: 91.0, lng: 0.0 } } } ] }.to_json)
    )

    expect(described_class.new("Somewhere impossible").coordinates).to be_nil
  end

  # A typing error is the usual cause of an address that gives nothing, and a second attempt with the
  # same text must not call an endpoint that costs money again.
  it "backs off briefly on an address that resolves to nothing" do
    allow(HTTParty).to receive(:get)
      .and_return(instance_double(HTTParty::Response, success?: true, body: { results: [] }.to_json))

    described_class.new("asdfgh").coordinates

    expect($redis).to have_received(:setex)
      .with(a_string_starting_with("google:maps:address:"), 5.minutes.to_i, ApplicationService::EMPTY_SENTINEL)
  end

  # An address is text that a user types. The raw text would put a space and a colon into the key.
  it "keys the cache on a digest, case-folded" do
    keys = []
    allow($redis).to receive(:get) { |key| keys << key and nil }

    described_class.new("Kona").coordinates
    described_class.new("kona").coordinates

    expect(keys.uniq).to contain_exactly(a_string_matching(/\Agoogle:maps:address:[0-9a-f]{8}\z/))
  end
end
