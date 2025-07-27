require 'spec_helper'

RSpec.describe LocationHelpers do
  let(:test_class) do
    Class.new do
      include LocationHelpers
      attr_accessor :data
      
      # Mock methods that would normally come from Rails or other helpers
      def number_to_rounded(number, options = {})
        number.round.to_s
      end
      
      def meters_to_feet(meters)
        meters * 3.28084
      end
      
      def units_tag(metric, imperial)
        "<span>#{metric} / #{imperial}</span>"
      end
    end
  end
  let(:test_instance) { test_class.new }
  
  let(:mock_data) { double('data') }
  let(:mock_location) { double('location') }
  let(:mock_geocoded) { double('geocoded') }
  let(:mock_address_components) { [] }
  let(:mock_time_zone) { double('time_zone') }

  before do
    test_instance.data = mock_data
    allow(mock_data).to receive(:location).and_return(mock_location)
    allow(mock_location).to receive(:geocoded).and_return(mock_geocoded)
    allow(mock_geocoded).to receive(:address_components).and_return(mock_address_components)
    allow(mock_location).to receive(:time_zone).and_return(mock_time_zone)
    allow(mock_time_zone).to receive(:time_zone_id).and_return('America/Denver')
    allow(mock_location).to receive(:elevation).and_return(1500.0)
    
    # These methods are now included in the test class
  end

  describe "#format_location" do
    context "with Jackson Hole, Wyoming" do
      let(:mock_address_components) do
        [
          double('county', types: ['administrative_area_level_2'], long_name: 'Teton County'),
          double('state', types: ['administrative_area_level_1'], long_name: 'Wyoming'),
          double('country', types: ['country'], long_name: 'United States')
        ]
      end

      it "returns the special Jackson Hole format" do
        expect(test_instance.format_location).to eq('Jackson Hole, Wyoming')
      end
    end

    context "with New York City" do
      let(:mock_address_components) do
        [
          double('city', types: ['locality'], long_name: 'New York'),
          double('state', types: ['administrative_area_level_1'], long_name: 'New York'),
          double('country', types: ['country'], long_name: 'United States')
        ]
      end

      it "returns the special NYC format" do
        expect(test_instance.format_location).to eq('New York City')
      end
    end

    context "with Washington, DC" do
      let(:mock_address_components) do
        [
          double('city', types: ['locality'], long_name: 'Washington'),
          double('state', types: ['administrative_area_level_1'], long_name: 'District of Columbia'),
          double('country', types: ['country'], long_name: 'United States')
        ]
      end

      it "returns the special DC format" do
        expect(test_instance.format_location).to eq('Washington, DC')
      end
    end

    context "with regular US city" do
      let(:mock_address_components) do
        [
          double('city', types: ['locality'], long_name: 'San Francisco'),
          double('state', types: ['administrative_area_level_1'], long_name: 'California'),
          double('country', types: ['country'], long_name: 'United States')
        ]
      end

      it "returns city and state format" do
        expect(test_instance.format_location).to eq('San Francisco, California')
      end
    end

    context "with locations containing apostrophes" do
      let(:mock_address_components) do
        [
          double('city', types: ['locality'], long_name: "Coeur d'Alene"),
          double('state', types: ['administrative_area_level_1'], long_name: 'Idaho'),
          double('country', types: ['country'], long_name: 'United States')
        ]
      end

      it "replaces straight quotes with curly quotes" do
        result = test_instance.format_location
        expect(result).to eq("Coeur d’Alene, Idaho")
      end
    end
  end

  describe "#format_elevation" do
    it "formats elevation in meters and feet" do
      result = test_instance.format_elevation
      expect(result).to include('1500 m')
      expect(result).to include('4921 feet') 
      expect(result).to include('<span>')
    end

    it "returns nil when elevation is blank" do
      allow(mock_location).to receive(:elevation).and_return(nil)
      expect(test_instance.format_elevation).to be_nil
    end
  end

  describe "#in_jackson_hole?" do
    it "returns true when location is Jackson Hole, Wyoming" do
      allow(test_instance).to receive(:format_location).with(mock_location).and_return('Jackson Hole, Wyoming')
      expect(test_instance.in_jackson_hole?).to be true
    end

    it "returns false when location is not Jackson Hole, Wyoming" do
      allow(test_instance).to receive(:format_location).with(mock_location).and_return('San Francisco, California')
      expect(test_instance.in_jackson_hole?).to be false
    end
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
