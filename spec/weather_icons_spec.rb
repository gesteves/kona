require 'spec_helper'
require 'yaml'

describe 'Condition Icons' do
  let(:weather_conditions) { YAML.load_file('data/conditions.yml') }
  let(:icons) { YAML.load_file('data/font_awesome.yml') }

  # Flatten the icon list for easier checking
  let(:flattened_icon_list) do
    icons['icons']['classic']['brands'] +
    icons['icons']['classic']['solid'] +
    icons['icons']['classic']['thin']
  end

  it 'ensures that the icon for every weather condition exists in the icon list' do
    weather_conditions.each do |condition, details|
      if details['icon'].is_a?(Hash)
        expect(flattened_icon_list).to include(details['icon']['day']), "Missing day icon for #{condition}: #{details['icon']['day']}"
        expect(flattened_icon_list).to include(details['icon']['night']), "Missing night icon for #{condition}: #{details['icon']['night']}"
      else
        expect(flattened_icon_list).to include(details['icon']), "Missing icon for #{condition}: #{details['icon']}"
      end
    end
  end
end
