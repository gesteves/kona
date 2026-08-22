require 'spec_helper'
require 'ostruct'

RSpec.describe IconHelpers do
  describe '#icon_svg' do
    # This has the shape of data.icons: family, then style, then [icons].
    def data
      OpenStruct.new(icons: {
        'classic' => {
          'light' => [ OpenStruct.new(id: 'calendar', svg: '<svg viewBox="0 0 448 512"><path/></svg>') ]
        }
      })
    end

    it 'returns the icon marked decorative (hidden from assistive tech, not focusable)' do
      svg = icon_svg('classic', 'light', 'calendar')
      expect(svg).to start_with('<svg aria-hidden="true" focusable="false"')
      expect(svg).to include('<path/>')
    end

    it 'is nil for an unknown icon, style, or family' do
      expect(icon_svg('classic', 'light', 'nope')).to be_nil
      expect(icon_svg('classic', 'solid', 'calendar')).to be_nil
      expect(icon_svg('sharp', 'light', 'calendar')).to be_nil
    end
  end

  describe '#clock_icon_svg' do
    # This returns the icon id that the code selected, and it does not read a true SVG.
    def icon_svg(_family, _style, icon_id) = icon_id

    def icon_at(hour, minute)
      clock_icon_svg(Time.new(2026, 6, 15, hour, minute, 0))
    end

    it 'rounds down to the hour before quarter past' do
      expect(icon_at(3, 0)).to eq('clock-three')
      expect(icon_at(3, 14)).to eq('clock-three')
    end

    it 'rounds to half-past between quarter past and quarter to' do
      expect(icon_at(3, 15)).to eq('clock-three-thirty')
      expect(icon_at(3, 44)).to eq('clock-three-thirty')
    end

    it 'rounds up to the next hour from quarter to' do
      expect(icon_at(2, 45)).to eq('clock-three')
      expect(icon_at(2, 59)).to eq('clock-three')
    end

    it "uses the bare 'clock' icon for four o'clock (there's no clock-four)" do
      expect(icon_at(4, 5)).to eq('clock')
      expect(icon_at(3, 50)).to eq('clock')
      expect(icon_at(4, 30)).to eq('clock-four-thirty')
    end

    it 'wraps around noon and midnight to twelve' do
      expect(icon_at(0, 5)).to eq('clock-twelve')
      expect(icon_at(12, 30)).to eq('clock-twelve-thirty')
      expect(icon_at(11, 50)).to eq('clock-twelve')
      expect(icon_at(23, 50)).to eq('clock-twelve')
    end

    it 'converts 24-hour times to the 12-hour clock face' do
      expect(icon_at(15, 0)).to eq('clock-three')
      expect(icon_at(21, 20)).to eq('clock-nine-thirty')
    end
  end
end
