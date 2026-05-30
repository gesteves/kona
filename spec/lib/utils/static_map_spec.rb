require 'spec_helper'
require 'tempfile'

# StaticMap reads MAPBOX_ACCESS_TOKEN at load time, so make sure one is set
# before the class is required.
ENV['MAPBOX_ACCESS_TOKEN'] ||= 'test-token'
require_relative '../../../lib/utils/static_map'

RSpec.describe StaticMap do
  # Builds a minimal GPX document for a track.
  def gpx_xml(name:, type:, with_time:, coordinates:)
    points = coordinates.each_with_index.map do |(lon, lat), i|
      time = with_time ? "<time>2025-05-01T08:0#{i}:00Z</time>" : ''
      %(<trkpt lon="#{lon}" lat="#{lat}">#{time}</trkpt>)
    end.join

    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1">
        <trk>
          <name>#{name}</name>
          <type>#{type}</type>
          <trkseg>#{points}</trkseg>
        </trk>
      </gpx>
    XML
  end

  # Instantiates a StaticMap from an in-memory GPX file.
  def build_map(name: 'Test Activity', type: 'running', with_time: true,
                coordinates: [[-117.0, 37.0], [-117.1, 37.1]], **options)
    Tempfile.create(['track', '.gpx']) do |file|
      file.write(gpx_xml(name: name, type: type, with_time: with_time, coordinates: coordinates))
      file.flush
      return described_class.new(file.path, options)
    end
  end

  describe '#initialize' do
    it 'raises when the GPX file does not exist' do
      expect { described_class.new('/nope/missing.gpx') }
        .to raise_error(/GPX file not found/)
    end

    it 'raises when the GPX file has no track points' do
      expect { build_map(coordinates: []) }
        .to raise_error('No track points found in GPX file')
    end

    it 'clamps an explicit height to MIN_HEIGHT' do
      # A tall padding makes the explicit-height branch active; a tiny height must
      # still be clamped up to MIN_HEIGHT.
      map = build_map(height: '10', padding: '1')
      expect(map.instance_variable_get(:@height)).to eq(StaticMap::MIN_HEIGHT)
    end
  end

  describe '#activity_title' do
    it 'strips the year from the name and prefixes it back' do
      map = build_map(name: '2025 Boston Marathon', type: 'running')
      expect(map.activity_title).to eq('2025 Boston Marathon')
    end

    it 'appends the activity type when the name has no activity keyword' do
      map = build_map(name: '2025 Big Event', type: 'running')
      expect(map.activity_title).to eq('2025 Big Event - Running')
    end

    it 'omits the year when the track has no timestamps' do
      map = build_map(name: 'Trail Run', type: 'running', with_time: false)
      expect(map.activity_title).to eq('Trail Run')
    end
  end

  describe '#validate_padding' do
    subject(:map) { build_map }

    it 'expands a single value to all four sides' do
      expect(map.send(:validate_padding, '50')).to eq('50,50,50,50')
    end

    it 'maps two values to top/bottom and left/right' do
      expect(map.send(:validate_padding, '50,100')).to eq('50,100,50,100')
    end

    it 'maps three values to top, left/right, bottom' do
      expect(map.send(:validate_padding, '50,100,75')).to eq('50,100,75,100')
    end

    it 'keeps four values as top, right, bottom, left' do
      expect(map.send(:validate_padding, '50,100,75,25')).to eq('50,100,75,25')
    end

    it 'ignores extra values beyond the first four' do
      expect(map.send(:validate_padding, '10,20,30,40,50')).to eq('10,20,30,40')
    end

    it 'falls back to the default padding for empty input' do
      expect(map.send(:validate_padding, '')).to eq("#{StaticMap::PADDING},#{StaticMap::PADDING},#{StaticMap::PADDING},#{StaticMap::PADDING}")
    end
  end

  describe '#top_and_bottom_padding' do
    subject(:map) { build_map }

    it 'sums the top and bottom values' do
      expect(map.send(:top_and_bottom_padding, '10,20,30,40')).to eq(40)
    end
  end

  describe '#calculate_bounding_box' do
    it 'expands a tiny span to at least the minimum viewable size' do
      map = build_map(min_km: 5)
      coords = [[-117.0, 37.0], [-117.0001, 37.0001]]
      box = map.send(:calculate_bounding_box, coords)

      min_viewable_lat = 5 / StaticMap::KM_PER_DEGREE
      expect(box[:max_lat] - box[:min_lat]).to be_within(1e-6).of(min_viewable_lat)
      expect(box[:max_lon] - box[:min_lon]).to be > 0.0001
    end

    it 'leaves a span larger than the minimum unchanged' do
      map = build_map(min_km: 1)
      coords = [[-117.0, 37.0], [-116.0, 38.0]]
      box = map.send(:calculate_bounding_box, coords)

      expect(box[:min_lat]).to eq(37.0)
      expect(box[:max_lat]).to eq(38.0)
    end
  end

  describe '#bounding_box_aspect_ratio' do
    subject(:map) { build_map }

    it 'computes width/height in kilometers' do
      # Centered on the equator so cos(lat) == 1 and the math is exact.
      box = { min_lon: 0.0, max_lon: 2.0, min_lat: -0.5, max_lat: 0.5 }
      expect(map.send(:bounding_box_aspect_ratio, box)).to be_within(1e-6).of(2.0)
    end

    it 'falls back to 1.0 for a degenerate (zero-height) box' do
      box = { min_lon: 0.0, max_lon: 2.0, min_lat: 1.0, max_lat: 1.0 }
      expect(map.send(:bounding_box_aspect_ratio, box)).to eq(1.0)
    end
  end

  describe '#select_icon' do
    it 'uses the activity icon for the start marker' do
      map = build_map(type: 'running')
      expect(map.send(:select_icon, :start_marker)).to eq(StaticMap::ACTIVITY_ICONS[:running])
    end

    it 'uses the finish icon for the end marker' do
      map = build_map(type: 'running')
      expect(map.send(:select_icon, :end_marker)).to eq(StaticMap::ACTIVITY_ICONS[:finish])
    end

    it 'uses the DNF icon for the end marker when the activity did not finish' do
      map = build_map(type: 'running', dnf: true)
      expect(map.send(:select_icon, :end_marker)).to eq(StaticMap::ACTIVITY_ICONS[:dnf])
    end

    it 'selects the swimming icon for swimming activities' do
      map = build_map(type: 'swimming')
      expect(map.send(:select_icon, :start_marker)).to eq(StaticMap::ACTIVITY_ICONS[:swimming])
    end

    it 'selects the cycling icon for cycling activities' do
      map = build_map(type: 'cycling')
      expect(map.send(:select_icon, :start_marker)).to eq(StaticMap::ACTIVITY_ICONS[:cycling])
    end
  end
end
