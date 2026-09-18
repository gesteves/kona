require "rails_helper"

RSpec.describe WeatherKit do
  subject(:service) { described_class.new(40.0, -105.0, "America/Denver", "US") }

  let(:private_key) { OpenSSL::PKey::EC.generate("prime256v1") }
  let(:weather_body) { { currentWeather: { temperature: 10.5 }, forecastDaily: { days: [] } }.to_json }

  def response(body, success: true, code: 200)
    instance_double(HTTParty::Response, success?: success, code: code, body: body, request: nil)
  end

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("WEATHERKIT_KEY_ID").and_return("KEY1")
    allow(ENV).to receive(:[]).with("WEATHERKIT_TEAM_ID").and_return("TEAM1")
    allow(ENV).to receive(:[]).with("WEATHERKIT_SERVICE_ID").and_return("com.example.weather")
    allow(ENV).to receive(:[]).with("WEATHERKIT_PRIVATE_KEY").and_return(Base64.strict_encode64(private_key.to_pem))
    allow(service).to receive(:sleep)

    keys = $redis.keys("weatherkit:*")
    $redis.del(*keys) if keys.any?

    allow(HTTParty).to receive(:get) do |url, **_options|
      url.include?("/availability/") ? response(%w[currentWeather forecastDaily].to_json) : response(weather_body)
    end
  end

  after do
    keys = $redis.keys("weatherkit:*")
    $redis.del(*keys) if keys.any?
  end

  it "signs an ES256 JWT for the key and the team, and keeps it in Redis for less than a minute" do
    service.data

    jwt = $redis.get("weatherkit:jwt")
    payload, header = JWT.decode(jwt, private_key, true, algorithm: "ES256")
    expect(header).to include("kid" => "KEY1", "id" => "TEAM1.com.example.weather")
    expect(payload).to include("iss" => "TEAM1", "sub" => "com.example.weather")
    expect(payload["exp"] - payload["iat"]).to eq(60)
    expect($redis.ttl("weatherkit:jwt")).to be_between(1, 50)
  end

  it "reads the availability first, then the weather for those data sets, with the bearer" do
    service.data

    expect(HTTParty).to have_received(:get).with(
      "#{WeatherKit::WEATHERKIT_API_URL}availability/40.0/-105.0",
      hash_including(query: { country: "US" }, timeout: WeatherKit::HTTP_TIMEOUT)
    ).ordered
    expect(HTTParty).to have_received(:get).with(
      "#{WeatherKit::WEATHERKIT_API_URL}weather/en/40.0/-105.0",
      hash_including(query: { country: "US", dataSets: "currentWeather,forecastDaily", timezone: "America/Denver" },
                     headers: { "Authorization" => a_string_starting_with("Bearer ") })
    ).ordered
  end

  it "gives the weather with snake_case keys and dot access" do
    expect(service.data.current_weather.temperature).to eq(10.5)
  end

  it "reuses the JWT in Redis and signs nothing" do
    $redis.setex("weatherkit:jwt", 50, "cached-jwt")
    allow(JWT).to receive(:encode)

    service.data

    expect(JWT).not_to have_received(:encode)
    expect(HTTParty).to have_received(:get)
      .with(anything, hash_including(headers: { "Authorization" => "Bearer cached-jwt" })).twice
  end

  # ⚠️ A token that the code cannot sign gives a 401 on each attempt. The code stops before the
  # request, and the report is the only message.
  it "gives nil, reports, and makes no request when the key cannot be signed" do
    allow(ENV).to receive(:[]).with("WEATHERKIT_PRIVATE_KEY").and_return(Base64.strict_encode64("not a key"))
    allow(ErrorReporter).to receive(:report_upstream)

    expect(service.data).to be_nil
    expect(HTTParty).not_to have_received(:get)
    expect(ErrorReporter).to have_received(:report_upstream)
      .with(kind_of(StandardError), hash_including(context: "WeatherKit JWT generation")).at_least(:once)
  end

  it "gives nil and makes no request with no coordinates, no zone, or no country" do
    expect(described_class.new(nil, nil, "America/Denver", "US").data).to be_nil
    expect(described_class.new(40.0, -105.0, "", "US").data).to be_nil
    expect(described_class.new(40.0, -105.0, "America/Denver", nil).data).to be_nil
    expect(HTTParty).not_to have_received(:get)
  end

  # ⚠️ The empty entry is a delay and not a cache: without it an outage costs the full retry budget
  # on each request of the widget.
  it "tries one more time after a failure, then keeps the failure out of the cache for a short time" do
    allow(HTTParty).to receive(:get).and_return(response("", success: false, code: 503))
    allow(ErrorReporter).to receive(:report_upstream)

    expect(service.data).to be_nil
    expect(HTTParty).to have_received(:get).twice
    ttl = $redis.ttl("weatherkit:availability:40.0:-105.0:America/Denver:US")
    expect(ttl).to be_between(1, WeatherKit::EMPTY_TTL.to_i)
  end

  # ⚠️ The two calls share one budget, thus the worst case is not two times as long.
  it "gives each call the time that stays in the shared budget" do
    allow(service).to receive(:with_retries).and_call_original

    service.data

    expect(service).to have_received(:with_retries)
      .with(hash_including(deadline: a_value <= WeatherKit::REQUEST_BUDGET)).twice
  end
end
