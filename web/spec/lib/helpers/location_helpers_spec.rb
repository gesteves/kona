require 'spec_helper'

RSpec.describe LocationHelpers do
  let(:test_class) do
    Class.new do
      include LocationHelpers
      attr_accessor :data
    end
  end
  let(:test_instance) { test_class.new }

  let(:mock_data) { double('data') }
  let(:mock_location) { double('location') }
  let(:mock_time_zone) { double('time_zone') }

  before do
    test_instance.data = mock_data
    allow(mock_data).to receive(:location).and_return(mock_location)
    allow(mock_location).to receive(:time_zone).and_return(mock_time_zone)
    allow(mock_time_zone).to receive(:time_zone_id).and_return('America/Denver')
  end

  describe "#location_time_zone" do
    it "returns the time zone ID from location data" do
      expect(test_instance.location_time_zone).to eq('America/Denver')
    end

    it "returns default time zone when location time zone is nil" do
      allow(mock_location).to receive(:time_zone).and_return(nil)
      expect(test_instance.location_time_zone).to eq('America/Denver')
    end

    it "returns default time zone when time zone ID is nil" do
      allow(mock_time_zone).to receive(:time_zone_id).and_return(nil)
      expect(test_instance.location_time_zone).to eq('America/Denver')
    end
  end

  describe "#current_time" do
    let(:mock_current_time) { double('current_time') }
    let(:mock_localized_time) { double('localized_time') }

    before do
      allow(Time).to receive(:current).and_return(mock_current_time)
      allow(mock_current_time).to receive(:in_time_zone).with('America/Denver').and_return(mock_localized_time)
      allow(test_instance).to receive(:location_time_zone).and_return('America/Denver')
    end

    it "returns current time in location's time zone" do
      expect(test_instance.current_time).to eq(mock_localized_time)
    end
  end
end
