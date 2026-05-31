require "rails_helper"

RSpec.describe GoogleMaps do
  subject(:maps) { described_class.new(43.48, -110.76) }

  let(:timezone_body) { { timeZoneId: "America/Denver", status: "OK" }.to_json }
  let(:geocode_body) do
    { results: [{ address_components: [{ types: ["country"], short_name: "US" }] }] }.to_json
  end
  let(:elevation_body) { { results: [{ elevation: 2057.0 }] }.to_json }

  before do
    # Cache always misses; writes are no-ops.
    allow($redis).to receive(:get).and_return(nil)
    allow($redis).to receive(:set)
    allow($redis).to receive(:setex)

    allow(HTTParty).to receive(:get) do |url, **_opts|
      body = case url
             when %r{/timezone/json} then timezone_body
             when %r{/geocode/json} then geocode_body
             when %r{/elevation/json} then elevation_body
             end
      instance_double(HTTParty::Response, success?: true, body: body)
    end
  end

  it "fetches only the timezone when asked only for time_zone_id" do
    expect(maps.time_zone_id).to eq("America/Denver")

    expect(HTTParty).to have_received(:get).with(a_string_matching(%r{/timezone/json}), any_args)
    expect(HTTParty).not_to have_received(:get).with(a_string_matching(%r{/geocode/json}), any_args)
    expect(HTTParty).not_to have_received(:get).with(a_string_matching(%r{/elevation/json}), any_args)
  end

  it "fetches only the geocode when asked only for the country code" do
    expect(maps.country_code).to eq("US")

    expect(HTTParty).to have_received(:get).with(a_string_matching(%r{/geocode/json}), any_args)
    expect(HTTParty).not_to have_received(:get).with(a_string_matching(%r{/timezone/json}), any_args)
  end

  it "assembles the full location hash (snake-cased) from all three lookups" do
    expect(maps.location).to eq(
      geocoded: { address_components: [{ types: ["country"], short_name: "US" }] },
      time_zone: { time_zone_id: "America/Denver", status: "OK" },
      elevation: 2057.0
    )
  end

  it "memoizes each lookup so repeated reads don't refetch" do
    maps.time_zone_id
    maps.time_zone_id
    expect(HTTParty).to have_received(:get).with(a_string_matching(%r{/timezone/json}), any_args).once
  end

  it "returns the default-free nils when coordinates are blank" do
    blank = described_class.new(nil, nil)
    expect(blank.time_zone_id).to be_nil
    expect(blank.country_code).to be_nil
    expect(HTTParty).not_to have_received(:get)
  end
end
