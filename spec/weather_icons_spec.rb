require 'spec_helper'
require 'yaml'

describe 'Condition Icons' do
  condition_codes = YAML.load_file('data/conditions.yml')

  it 'checks if SVG files exist for condition icons' do
    condition_codes.each do |code, data|
      next unless data['icon']

      if data['icon'].is_a?(String)
        svg_file = "#{data['icon']}.svg"
        icon_path = File.join('source/icons/thin', svg_file)

        expect(File.exist?(icon_path)).to be(true), "SVG file #{icon_path} not found for condition code #{code}"
      else
        if data['icon']['day']
          day_svg_file = "#{data['icon']['day']}.svg"
          day_icon_path = File.join('source/icons/thin', day_svg_file)

          expect(File.exist?(day_icon_path)).to be(true), "Day SVG file #{day_icon_path} not found for condition code #{code}"
        end

        if data['icon']['night']
          night_svg_file = "#{data['icon']['night']}.svg"
          night_icon_path = File.join('source/icons/thin', night_svg_file)

          expect(File.exist?(night_icon_path)).to be(true), "Night SVG file #{night_icon_path} not found for condition code #{code}"
        end
      end
    end
  end
end
