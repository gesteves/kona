require "rails_helper"

RSpec.describe Lastfm do
  subject(:service) { described_class.new }

  let(:workout_start) { Time.utc(2026, 7, 9, 13, 30) }
  let(:workout_end) { Time.utc(2026, 7, 9, 14, 30) }

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("LASTFM_USERNAME").and_return("listener")
    allow(ENV).to receive(:[]).with("LASTFM_API_KEY").and_return("key")
  end

  def scrobble(name, artist: "Artist", uts: workout_start.to_i, loved: "0", now_playing: false)
    track = {
      name: name,
      url: "https://last.fm/#{name.parameterize}",
      artist: { "#text": artist },
      album: { "#text": "Album" },
      loved: loved
    }
    track[:date] = { uts: uts.to_s } unless now_playing
    track[:"@attr"] = { nowplaying: "true" } if now_playing
    track
  end

  def stub_recent_tracks(tracks)
    allow(service).to receive(:get_json!).with(
      Lastfm::LASTFM_API_URL,
      query: hash_including(method: "user.getrecenttracks")
    ).and_return({ recenttracks: { track: tracks } })
  end

  def stub_track_info(duration_ms)
    allow(service).to receive(:get_json!).with(
      Lastfm::LASTFM_API_URL,
      query: hash_including(method: "track.getInfo")
    ).and_return({ track: { duration: duration_ms.to_s } })
  end

  describe "#configured?" do
    it "requires both credentials" do
      expect(service.configured?).to be(true)

      allow(ENV).to receive(:[]).with("LASTFM_API_KEY").and_return(nil)
      expect(described_class.new.configured?).to be(false)
    end
  end

  describe "#played_songs_during" do
    it "returns [] without credentials" do
      allow(ENV).to receive(:[]).with("LASTFM_USERNAME").and_return(nil)

      expect(described_class.new.played_songs_during(workout_start, workout_end)).to eq([])
    end

    it "queries with a 5-minute pre-start buffer" do
      stub_recent_tracks([])

      service.played_songs_during(workout_start, workout_end)

      expect(service).to have_received(:get_json!).with(
        Lastfm::LASTFM_API_URL,
        query: hash_including(from: (workout_start - 5.minutes).to_i, to: workout_end.to_i, extended: 1)
      )
    end

    it "drops now-playing entries (no scrobble date)" do
      stub_recent_tracks([scrobble("Live", now_playing: true), scrobble("Dated")])

      songs = service.played_songs_during(workout_start, workout_end)

      expect(songs.map { |s| s[:name] }).to eq(["Dated"])
    end

    it "keeps in-window scrobbles chronologically with the loved flag" do
      stub_recent_tracks([
        scrobble("Second", uts: workout_start.to_i + 600, loved: "1"),
        scrobble("First", uts: workout_start.to_i + 60)
      ])

      songs = service.played_songs_during(workout_start, workout_end)

      expect(songs.map { |s| s[:name] }).to eq(%w[First Second])
      expect(songs.last[:loved]).to be(true)
      expect(songs.first[:loved]).to be(false)
    end

    it "skips the track.getInfo lookup for in-window scrobbles" do
      stub_recent_tracks([scrobble("In Window", uts: workout_start.to_i + 60)])
      stub_track_info(3 * 60 * 1000)

      service.played_songs_during(workout_start, workout_end)

      expect(service).not_to have_received(:get_json!).with(
        Lastfm::LASTFM_API_URL,
        query: hash_including(method: "track.getInfo")
      )
    end

    it "keeps a pre-start scrobble whose duration overlaps the start" do
      stub_recent_tracks([scrobble("Long Intro", uts: (workout_start - 3.minutes).to_i)])
      stub_track_info(5 * 60 * 1000) # 5 minutes — still playing at start

      songs = service.played_songs_during(workout_start, workout_end)

      expect(songs.map { |s| s[:name] }).to eq(["Long Intro"])
    end

    it "drops a pre-start scrobble that ended before the start" do
      stub_recent_tracks([scrobble("Short", uts: (workout_start - 3.minutes).to_i)])
      stub_track_info(2 * 60 * 1000) # 2 minutes — over before the start

      expect(service.played_songs_during(workout_start, workout_end)).to eq([])
    end

    it "keeps a pre-start scrobble conservatively when the duration is unknown" do
      stub_recent_tracks([scrobble("Obscure", uts: (workout_start - 3.minutes).to_i)])
      stub_track_info(0)

      songs = service.played_songs_during(workout_start, workout_end)

      expect(songs.map { |s| s[:name] }).to eq(["Obscure"])
    end

    it "keeps a pre-start scrobble conservatively when the lookup fails" do
      stub_recent_tracks([scrobble("Flaky", uts: (workout_start - 3.minutes).to_i)])
      allow(service).to receive(:get_json!).with(
        Lastfm::LASTFM_API_URL,
        query: hash_including(method: "track.getInfo")
      ).and_raise(ApplicationService::HttpError.new(500, "boom", "url"))

      songs = service.played_songs_during(workout_start, workout_end)

      expect(songs.map { |s| s[:name] }).to eq(["Flaky"])
    end

    it "tolerates Last.fm's single-track (non-array) response shape" do
      stub_recent_tracks(scrobble("Only One"))

      songs = service.played_songs_during(workout_start, workout_end)

      expect(songs.map { |s| s[:name] }).to eq(["Only One"])
    end

    it "raises on a Last.fm error body" do
      allow(service).to receive(:get_json!).and_return({ error: 10, message: "Invalid API key" })

      expect { service.played_songs_during(workout_start, workout_end) }.to raise_error(/Invalid API key/)
    end

    it "does not retry a permanent Last.fm error body" do
      allow(service).to receive(:sleep)
      allow(service).to receive(:get_json!).and_return({ error: 10, message: "Invalid API key" })

      expect { service.played_songs_during(workout_start, workout_end) }.to raise_error(/Invalid API key/)
      expect(service).to have_received(:get_json!).once
      expect(service).not_to have_received(:sleep)
    end

    it "retries a transient failure on the recent-tracks fetch" do
      allow(service).to receive(:sleep) # skip the real backoff delay
      attempt = 0
      allow(service).to receive(:get_json!).with(
        Lastfm::LASTFM_API_URL,
        query: hash_including(method: "user.getrecenttracks")
      ) do
        attempt += 1
        raise ApplicationService::HttpError.new(500, "boom", "url") if attempt == 1

        { recenttracks: { track: [scrobble("Recovered")] } }
      end

      songs = service.played_songs_during(workout_start, workout_end)

      expect(songs.map { |s| s[:name] }).to eq(["Recovered"])
      expect(attempt).to eq(2)
    end
  end
end
