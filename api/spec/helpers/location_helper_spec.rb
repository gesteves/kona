require "rails_helper"

RSpec.describe LocationHelper do
  def helper_at(*components)
    Class.new do
      include ActionView::Helpers::TagHelper
      include UnitsHelper
      include MarkupHelper
      include LocationHelper
    end.new.tap do |h|
      h.instance_variable_set(:@location, DeepOstruct.wrap(geocoded: { address_components: components }))
    end
  end

  def component(types, long_name)
    { types: types, long_name: long_name }
  end

  describe "#format_location" do
    it "formats a US location as City, State" do
      helper = helper_at(
        component(%w[locality], "Boulder"),
        component(%w[administrative_area_level_1], "Colorado"),
        component(%w[country], "United States")
      )
      expect(helper.format_location).to eq("Boulder, Colorado")
    end

    it "special-cases Teton County, Wyoming as Jackson Hole" do
      helper = helper_at(
        component(%w[administrative_area_level_2], "Teton County"),
        component(%w[administrative_area_level_1], "Wyoming"),
        component(%w[country], "United States")
      )
      expect(helper.format_location).to eq("Jackson Hole, Wyoming")
      expect(helper.in_jackson_hole?).to be true
    end

    it "special-cases New York, New York as New York City" do
      helper = helper_at(
        component(%w[locality], "New York"),
        component(%w[administrative_area_level_1], "New York"),
        component(%w[country], "United States")
      )
      expect(helper.format_location).to eq("New York City")
    end

    it "special-cases the District of Columbia as Washington, DC" do
      helper = helper_at(
        component(%w[locality], "Washington"),
        component(%w[administrative_area_level_1], "District of Columbia"),
        component(%w[country], "United States")
      )
      expect(helper.format_location).to eq("Washington, DC")
    end

    it "formats other countries as City, Country" do
      helper = helper_at(
        component(%w[locality], "Paris"),
        component(%w[country], "France")
      )
      expect(helper.format_location).to eq("Paris, France")
    end

    it "curls apostrophes in place names" do
      helper = helper_at(
        component(%w[locality], "Coeur d'Alene"),
        component(%w[administrative_area_level_1], "Idaho"),
        component(%w[country], "United States")
      )
      expect(helper.format_location).to eq("Coeur d’Alene, Idaho")
    end

    it "detects San Francisco" do
      helper = helper_at(
        component(%w[locality], "San Francisco"),
        component(%w[administrative_area_level_1], "California"),
        component(%w[country], "United States")
      )
      expect(helper.in_san_francisco?).to be true
    end
  end

  describe "#format_elevation" do
    it "renders a metric/imperial elevation toggle" do
      helper = helper_at(component(%w[country], "United States"))
      result = helper.format_elevation(1655.0)
      expect(result).to include("1,655 m")
      expect(result).to include("5,430 feet")
      expect(result).to include('data-controller="units"')
    end
  end
end
