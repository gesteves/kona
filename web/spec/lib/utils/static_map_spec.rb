require 'spec_helper'

# lib/utils/static_map.rb reads Mapbox ENV vars into constants at load time (and raises
# if MAPBOX_ACCESS_TOKEN is missing), so pin deterministic values before requiring it.
# These only affect the test process, never the shell.
ENV['MAPBOX_ACCESS_TOKEN'] = 'pk.test-token'
ENV['MAPBOX_SECRET_TOKEN'] = 'sk.test-token'
ENV['MAPBOX_STYLE_URL'] = 'mapbox://styles/testuser/teststyle'
require_relative '../../../lib/utils/static_map'

RSpec.describe StaticMap do
  # The initializer parses a GPX file from disk and derives everything from it; allocate
  # skips that so the pure geometry/formatting methods can be exercised against
  # hand-built instance variables (same pattern as spec/lib/data/contentful_spec.rb).
  def build_map(ivars = {})
    defaults = {
      activity_name: 'Morning Run',
      activity_type: 'Running',
      activity_start: nil,
      dnf: false,
      reverse_markers: false,
      margins_km: [0.0, 0.0, 0.0, 0.0],
      padding: '50,50,50,50',
      tileset_id: nil,
      source_layer: 'track',
      coordinates: [[10.0, 50.0], [10.5, 50.5], [11.0, 51.0]],
      bounding_box: { min_lon: 10.0, max_lon: 11.0, min_lat: 50.0, max_lat: 51.0 },
      width: 1280,
      height: 800
    }
    described_class.allocate.tap do |map|
      defaults.merge(ivars).each do |name, value|
        map.instance_variable_set(:"@#{name}", value)
      end
    end
  end

  describe '#calculate_bounding_box' do
    it 'returns the min/max longitude and latitude of the track with zero margins' do
      map = build_map(margins_km: [0.0, 0.0, 0.0, 0.0])
      box = map.send(:calculate_bounding_box, [[10.0, 50.0], [10.5, 50.2], [11.0, 51.0]])
      expect(box).to eq(min_lon: 10.0, max_lon: 11.0, min_lat: 50.0, max_lat: 51.0)
    end

    it 'expands only the top edge by the top margin, converted from km to degrees of latitude' do
      map = build_map(margins_km: [2.0, 0.0, 0.0, 0.0])
      box = map.send(:calculate_bounding_box, [[10.0, 50.0], [11.0, 51.0]])
      expect(box[:max_lat]).to be_within(1e-9).of(51.0 + 2.0 / 111.32)
      expect(box[:min_lat]).to eq(50.0)
      expect(box[:min_lon]).to eq(10.0)
      expect(box[:max_lon]).to eq(11.0)
    end

    it 'scales longitude margins by the cosine of the center latitude' do
      map = build_map(margins_km: [0.0, 1.0, 0.0, 3.0])
      box = map.send(:calculate_bounding_box, [[10.0, 50.0], [11.0, 51.0]])
      cos = Math.cos(50.5 * Math::PI / 180) # center latitude of the track
      expect(box[:max_lon]).to be_within(1e-9).of(11.0 + 1.0 / (111.32 * cos))
      expect(box[:min_lon]).to be_within(1e-9).of(10.0 - 3.0 / (111.32 * cos))
      expect(box[:min_lat]).to eq(50.0)
      expect(box[:max_lat]).to eq(51.0)
    end
  end

  describe '#bounding_box_aspect_ratio' do
    it 'returns width/height in physical km, so a square box at the equator is 1.0' do
      map = build_map
      box = { min_lon: -1.0, max_lon: 1.0, min_lat: -1.0, max_lat: 1.0 }
      expect(map.send(:bounding_box_aspect_ratio, box)).to be_within(1e-9).of(1.0)
    end

    it 'returns 2.0 for a box twice as wide as tall at the equator' do
      map = build_map
      box = { min_lon: -1.0, max_lon: 1.0, min_lat: -0.5, max_lat: 0.5 }
      expect(map.send(:bounding_box_aspect_ratio, box)).to be_within(1e-9).of(2.0)
    end

    it 'narrows the effective width at high latitudes (1° lon ≈ 0.5° lat worth of km at 60°N)' do
      map = build_map
      box = { min_lon: 10.0, max_lon: 11.0, min_lat: 59.5, max_lat: 60.5 }
      expect(map.send(:bounding_box_aspect_ratio, box)).to be_within(1e-9).of(Math.cos(60 * Math::PI / 180))
    end

    it 'falls back to 1.0 when the box has no height (infinite ratio)' do
      map = build_map
      box = { min_lon: 10.0, max_lon: 11.0, min_lat: 50.0, max_lat: 50.0 }
      expect(map.send(:bounding_box_aspect_ratio, box)).to eq(1.0)
    end

    it 'falls back to 1.0 when the box has no width (zero ratio is not positive)' do
      map = build_map
      box = { min_lon: 10.0, max_lon: 10.0, min_lat: 50.0, max_lat: 51.0 }
      expect(map.send(:bounding_box_aspect_ratio, box)).to eq(1.0)
    end

    it 'falls back to 1.0 for a single-point box (NaN ratio)' do
      map = build_map
      box = { min_lon: 10.0, max_lon: 10.0, min_lat: 50.0, max_lat: 50.0 }
      expect(map.send(:bounding_box_aspect_ratio, box)).to eq(1.0)
    end
  end

  describe '#cos_lat' do
    it 'returns 1.0 at the equator' do
      expect(build_map.send(:cos_lat, 0)).to eq(1.0)
    end

    it 'returns cos(60°) ≈ 0.5 at 60 degrees latitude' do
      expect(build_map.send(:cos_lat, 60)).to be_within(1e-9).of(0.5)
    end
  end

  describe '#parse_box_shorthand' do
    it 'applies a single value to all four sides' do
      expect(build_map.send(:parse_box_shorthand, '5', default: 0, cast: :to_f)).to eq([5.0, 5.0, 5.0, 5.0])
    end

    it 'expands two values as top/bottom and left/right, like CSS' do
      expect(build_map.send(:parse_box_shorthand, '1,2', default: 0, cast: :to_f)).to eq([1.0, 2.0, 1.0, 2.0])
    end

    it 'expands three values as top, left/right, bottom' do
      expect(build_map.send(:parse_box_shorthand, '1,2,3', default: 0, cast: :to_f)).to eq([1.0, 2.0, 3.0, 2.0])
    end

    it 'keeps four values as top, right, bottom, left' do
      expect(build_map.send(:parse_box_shorthand, '1,2,3,4', default: 0, cast: :to_f)).to eq([1.0, 2.0, 3.0, 4.0])
    end

    it 'ignores values past the fourth' do
      expect(build_map.send(:parse_box_shorthand, '1,2,3,4,5,6', default: 0, cast: :to_f)).to eq([1.0, 2.0, 3.0, 4.0])
    end

    it 'falls back to the default on all sides for nil or empty input' do
      expect(build_map.send(:parse_box_shorthand, nil, default: 7, cast: :to_f)).to eq([7, 7, 7, 7])
      expect(build_map.send(:parse_box_shorthand, '', default: 7, cast: :to_f)).to eq([7, 7, 7, 7])
    end

    it 'strips whitespace and skips empty segments' do
      expect(build_map.send(:parse_box_shorthand, ' 1 , , 2 ', default: 0, cast: :to_f)).to eq([1.0, 2.0, 1.0, 2.0])
    end

    it 'accepts a bare numeric and casts with the given method' do
      expect(build_map.send(:parse_box_shorthand, 50, default: 0, cast: :to_i)).to eq([50, 50, 50, 50])
      expect(build_map.send(:parse_box_shorthand, '2.5', default: 0, cast: :to_i)).to eq([2, 2, 2, 2])
    end
  end

  describe '#validate_padding' do
    it 'normalizes a single integer to a four-sided Mapbox padding string' do
      expect(build_map.send(:validate_padding, 50)).to eq('50,50,50,50')
    end

    it 'expands two-value shorthand into top,right,bottom,left' do
      expect(build_map.send(:validate_padding, '10,20')).to eq('10,20,10,20')
    end

    it 'falls back to the 50px default when nothing parses' do
      expect(build_map.send(:validate_padding, nil)).to eq('50,50,50,50')
    end

    it 'truncates fractional values to integers' do
      expect(build_map.send(:validate_padding, '10.7,20.2')).to eq('10,20,10,20')
    end
  end

  describe '#activity_title' do
    it 'moves the year from the GPX name to the front when the start date is known' do
      map = build_map(activity_name: 'Boston Marathon 2024', activity_type: 'Running',
                      activity_start: DateTime.parse('2024-04-15T09:00:00Z'))
      expect(map.activity_title).to eq('2024 Boston Marathon')
    end

    it 'appends the activity type when the title has no recognizable sport keyword' do
      map = build_map(activity_name: 'Ironman Boulder 2024', activity_type: 'Cycling',
                      activity_start: DateTime.parse('2024-06-01T07:00:00Z'))
      expect(map.activity_title).to eq('2024 Ironman Boulder - Cycling')
    end

    it 'uses the raw name without a year when the GPX has no start time' do
      map = build_map(activity_name: 'Morning Run', activity_type: 'Running', activity_start: nil)
      expect(map.activity_title).to eq('Morning Run')
    end

    it 'still appends the type for keyword-less names without a start time' do
      map = build_map(activity_name: 'Morning Ride', activity_type: 'Cycling', activity_start: nil)
      expect(map.activity_title).to eq('Morning Ride - Cycling')
    end

    it 'leaves a double space behind when the year appears mid-name (pins current behavior)' do
      # gsub removes the year but strip only trims the ends, so an interior year
      # leaves two consecutive spaces. Pinned as-is; a squish would change existing ids.
      map = build_map(activity_name: 'IM 2024 Boulder', activity_type: 'Running',
                      activity_start: DateTime.parse('2024-06-01T07:00:00Z'))
      expect(map.activity_title).to eq('2024 IM  Boulder - Running')
    end
  end

  describe '#tileset_source_id' do
    it 'builds an underscored slug from the title plus an 8-char digest of the full title' do
      map = build_map(activity_name: 'Boston Marathon 2024', activity_type: 'Running',
                      activity_start: DateTime.parse('2024-04-15T09:00:00Z'))
      expect(map.send(:tileset_source_id)).to eq('2024_boston_marathon_34c6e09b')
    end

    it 'truncates the slug to 23 chars and strips a trailing underscore before the digest' do
      # "morning_run_around_the_park" cut at 23 chars ends in "the_"; the dangling
      # underscore is stripped so the id reads "..._the_<digest>", not "..._the__<digest>".
      map = build_map(activity_name: 'Morning Run Around The Park', activity_type: 'Running',
                      activity_start: nil)
      expect(map.send(:tileset_source_id)).to eq('morning_run_around_the_4e481c66')
    end

    it 'stays within Mapbox limits: at most 32 chars of letters, numbers, and underscores' do
      map = build_map(activity_name: 'A Very Long Activity Name That Goes On And On 2024',
                      activity_type: 'Cycling', activity_start: DateTime.parse('2024-01-01T00:00:00Z'))
      id = map.send(:tileset_source_id)
      expect(id.length).to be <= 32
      expect(id).to match(/\A[a-z0-9_]+\z/)
    end
  end

  describe '#select_icon' do
    it 'uses the danger icon for the end marker of a DNF' do
      expect(build_map(dnf: true).send(:select_icon, :end_marker)).to eq('danger')
    end

    it 'uses the racetrack icon for a normal finish' do
      expect(build_map(dnf: false).send(:select_icon, :end_marker)).to eq('racetrack')
    end

    it 'picks the start icon from the activity type' do
      expect(build_map(activity_type: 'Open Water Swimming').send(:select_icon, :start_marker)).to eq('swimming')
      expect(build_map(activity_type: 'Cycling').send(:select_icon, :start_marker)).to eq('bicycle-share')
      expect(build_map(activity_type: 'Mountain Biking').send(:select_icon, :start_marker)).to eq('bicycle-share')
      expect(build_map(activity_type: 'Trail Running').send(:select_icon, :start_marker)).to eq('pitch')
    end

    it 'falls back to the rocket icon for unrecognized activity types' do
      expect(build_map(activity_type: 'Hiking').send(:select_icon, :start_marker)).to eq('rocket')
    end

    it 'keeps the sport icon on the start marker even for a DNF (only the finish changes)' do
      expect(build_map(dnf: true, activity_type: 'Running').send(:select_icon, :start_marker)).to eq('pitch')
    end
  end

  describe '#mapbox_image_url' do
    it 'builds the static-images URL with the finish marker first, bbox, size, and render token' do
      map = build_map
      expect(map.send(:mapbox_image_url)).to eq(
        'https://api.mapbox.com/styles/v1/testuser/teststyle/static/' \
        'pin-l-racetrack+F90F1A(11.0,51.0),pin-l-pitch+18A644(10.0,50.0)/' \
        '%5B10.0,50.0,11.0,51.0%5D/1280x800@2x?access_token=sk.test-token&padding=50%2C50%2C50%2C50'
      )
    end

    it 'swaps the marker order when reverse_markers is set' do
      map = build_map(reverse_markers: true)
      expect(map.send(:mapbox_image_url)).to include(
        '/static/pin-l-pitch+18A644(10.0,50.0),pin-l-racetrack+F90F1A(11.0,51.0)/'
      )
    end

    it 'appends the track layer under road labels when a tileset id is set' do
      map = build_map(tileset_id: 'testuser.morning_run_4e481c66', source_layer: 'track')
      url = map.send(:mapbox_image_url)
      # The layer JSON is appended raw (only the # in the line color is pre-encoded);
      # pinned as-is since Mapbox accepts it.
      expect(url).to end_with(
        '&addlayer={"id":"testuser.morning_run_4e481c66","type":"line",' \
        '"source":{"type":"vector","url":"mapbox://testuser.morning_run_4e481c66"},' \
        '"source-layer":"track","paint":{"line-color":"%23BF0222","line-width":4,' \
        '"line-opacity":0.75,"line-cap":"round","line-join":"round"}}&before_layer=road-label'
      )
    end

    it 'omits the addlayer parameter entirely without a tileset' do
      map = build_map(tileset_id: nil)
      expect(map.send(:mapbox_image_url)).not_to include('addlayer')
    end
  end

  describe '#get_with_retries' do
    def response_double(success:, code:)
      double('HTTParty::Response', success?: success, code: code)
    end

    it 'returns the response immediately on success' do
      good = response_double(success: true, code: 200)
      allow(HTTParty).to receive(:get).and_return(good)

      expect(build_map.send(:get_with_retries, 'https://example.com/map.png')).to eq(good)
      expect(HTTParty).to have_received(:get).once
    end

    it 'retries a 5xx (sleeping between attempts) and returns the eventual success' do
      bad = response_double(success: false, code: 503)
      good = response_double(success: true, code: 200)
      allow(HTTParty).to receive(:get).and_return(bad, good)
      map = build_map
      allow(map).to receive(:sleep)

      expect(map.send(:get_with_retries, 'https://example.com/map.png')).to eq(good)
      expect(HTTParty).to have_received(:get).twice
      expect(map).to have_received(:sleep).with(1)
    end

    it 'returns a 4xx without retrying (the caller raises via error_message_from)' do
      bad = response_double(success: false, code: 404)
      allow(HTTParty).to receive(:get).and_return(bad)

      expect(build_map.send(:get_with_retries, 'https://example.com/map.png')).to eq(bad)
      expect(HTTParty).to have_received(:get).once
    end

    it 'returns the failed response after exhausting retries on persistent 5xx (pins current behavior)' do
      # On the final attempt the `attempt >= HTTP_MAX_ATTEMPTS` guard returns the 5xx
      # response instead of raising; download_image is what turns it into an error.
      bad = response_double(success: false, code: 500)
      allow(HTTParty).to receive(:get).and_return(bad)
      map = build_map
      allow(map).to receive(:sleep)

      expect(map.send(:get_with_retries, 'https://example.com/map.png')).to eq(bad)
      expect(HTTParty).to have_received(:get).exactly(3).times
      expect(map).to have_received(:sleep).with(1).once
      expect(map).to have_received(:sleep).with(2).once
    end

    it 're-raises a network error after exhausting all attempts with backoff' do
      allow(HTTParty).to receive(:get).and_raise(SocketError.new('getaddrinfo failed'))
      map = build_map
      allow(map).to receive(:sleep)

      expect {
        map.send(:get_with_retries, 'https://example.com/map.png')
      }.to raise_error(SocketError, 'getaddrinfo failed')
      expect(HTTParty).to have_received(:get).exactly(3).times
      expect(map).to have_received(:sleep).with(1).once
      expect(map).to have_received(:sleep).with(2).once
    end
  end

  describe '#error_message_from' do
    def response_double(body:, code:)
      double('HTTParty::Response', body: body, code: code)
    end

    it 'extracts the message from a JSON error body' do
      response = response_double(body: '{"message":"Not Authorized - Invalid Token"}', code: 401)
      expect(build_map.send(:error_message_from, response)).to eq('Not Authorized - Invalid Token')
    end

    it 'falls back to the status code when the body is not JSON' do
      response = response_double(body: '<html>Bad Gateway</html>', code: 502)
      expect(build_map.send(:error_message_from, response)).to eq('Mapbox request failed with status 502')
    end

    it 'falls back to the status code when the JSON has no message' do
      response = response_double(body: '{"error":"nope"}', code: 422)
      expect(build_map.send(:error_message_from, response)).to eq('Mapbox request failed with status 422')
    end

    it 'falls back to the status code when the body is nil' do
      response = response_double(body: nil, code: 500)
      expect(build_map.send(:error_message_from, response)).to eq('Mapbox request failed with status 500')
    end
  end
end
