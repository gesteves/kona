require 'spec_helper'

RSpec.describe UnitHelpers do
  describe '#distance' do
    context 'when using metric units' do
      it 'converts meters to kilometers correctly' do
        expect(distance(1234, units: 'metric')).to eq('1.2 kilometers')
        expect(distance(12345, units: 'metric')).to eq('12.3 kilometers')
        expect(distance(123456, units: 'metric')).to eq('123.5 kilometers')
        expect(distance(1234567, units: 'metric')).to eq('1,235 kilometers')
      end

      it 'keeps meters for distances less than 1 km' do
        expect(distance(999, units: 'metric')).to eq('999 meters')
      end
    end

    context 'when using imperial units' do
      it 'converts meters to miles correctly' do
        expect(distance(2000, units: 'imperial')).to eq('1.2 miles')
        expect(distance(20000, units: 'imperial')).to eq('12.4 miles')
        expect(distance(200000, units: 'imperial')).to eq('124.3 miles')
        expect(distance(2000000, units: 'imperial')).to eq('1,243 miles')
      end

      it 'uses yards for distances less than 1 mile' do
        expect(distance(1000, units: 'imperial')).to eq('1,094 yards')
      end
    end
  end

  describe '#distance_value' do
    it 'returns just the numeric part of the distance' do
      expect(distance_value(1234, units: 'metric')).to eq('1.2')
      expect(distance_value(2000, units: 'imperial')).to eq('1.2')
    end
  end

  describe '#distance_unit' do
    it 'returns just the unit part of the distance' do
      expect(distance_unit(1234, units: 'metric')).to eq('kilometers')
      expect(distance_unit(2000, units: 'imperial')).to eq('miles')
    end
  end

  describe '#millimeters_to_inches' do
    it 'converts millimeters to inches correctly' do
      expect(millimeters_to_inches(25.4)).to eq(1.0)
    end
  end

  describe '#celsius_to_fahrenheit' do
    it 'converts Celsius to Fahrenheit correctly' do
      expect(celsius_to_fahrenheit(0)).to eq(32.0)
      expect(celsius_to_fahrenheit(100)).to eq(212.0)
    end
  end
end
