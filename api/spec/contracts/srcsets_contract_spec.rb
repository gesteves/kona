require "rails_helper"

# config/srcsets.yml is a copy of web/data/srcsets.yml. The api renders the trending card and the
# build renders each other card, and the two go on the same page. Thus a difference gives one image
# at the wrong size, or a `sizes` that describes the wrong element, in the middle of one section.
# Nothing else compares the two, and neither app reads the file of the other one: the Docker image
# of this app holds `api/` only.
RSpec.describe "web ↔ api srcsets contract" do
  api_path = Rails.root.join("config/srcsets.yml")
  web_path = Rails.root.join("../web/data/srcsets.yml")

  it "keeps config/srcsets.yml the same as web/data/srcsets.yml, word for word" do
    expect(File.read(api_path)).to eq(File.read(web_path)),
      "config/srcsets.yml and web/data/srcsets.yml are different. " \
      "Run `cp web/data/srcsets.yml api/config/srcsets.yml` from the root of the repo."
  end

  # ⚠️ This is the reason for the copy. The two checks above and below are not the same: the file
  # can be equal and the helper can still read the wrong key.
  it "renders the card from the `card` variant of that file" do
    card = YAML.load_file(web_path).fetch("card")

    expect(ImagesHelper::CARD_SIZES).to eq(card.fetch("sizes").join(", "))
    expect(ImagesHelper::CARD_WIDTHS).to eq(card.fetch("widths"))
  end

  # `cover_image_tag` reads widths.first for the `src`. With the list in another order, the src
  # would be a candidate for a phone, and each desktop card would then be soft.
  it "keeps the 1x desktop width first in the card widths" do
    expect(ImagesHelper::CARD_WIDTHS.first).to eq(592)
    expect(ImagesHelper::CARD_SIZES).to include("(min-width: 1280px) 592px")
  end
end
