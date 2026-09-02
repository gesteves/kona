require "rails_helper"

# The admin JavaScript reads its words from a `data-admin-i18n` table (refer to AdminHelper#
# admin_i18n_data and app/javascript/lib/i18n.js). `t` in that file gives an empty string for a key
# that the table does not hold, with no message, and no spec renders those words. This spec finds
# each key in the source and checks that the locale file holds it below the scope of its view.
RSpec.describe "Admin JavaScript i18n keys" do
  # The scope that each view gives to the controller of a file. The location view also gives
  # `state: "admin.location.state"`, thus the `state.*` keys of that file are below admin.location.
  SCOPES = {
    "location_map_controller.js" => %w[admin.js.location admin.location],
    "social_controller.js" => %w[admin.js.social],
    "social_post_controller.js" => %w[admin.js.social_post],
    "republish_controller.js" => %w[admin.js.republish]
  }.freeze

  # A key in `this.words("…")` or `t(this.words, "…")`. A key in a template literal names its
  # part at run time, and the spec reads the parts before the `${`.
  KEY_CALL = /(?:this\.words\(|t\(this\.words, )(?:"([^"]+)"|`([^`]+)`)/

  SCOPES.each do |file, scopes|
    it "names keys of #{file} that config/locales/en.yml holds" do
      source = Rails.root.join("app/javascript/controllers", file).read
      keys = source.scan(KEY_CALL).map { |plain, literal| plain || literal.split("${").first.chomp(".") }
      expect(keys).not_to be_empty, "#{file} reads no keys, thus this spec covers nothing."

      keys.uniq.each do |key|
        found = scopes.any? do |scope|
          I18n.exists?("#{scope}.#{key}") || I18n.t("#{scope}.#{key}", default: nil).is_a?(Hash)
        end
        expect(found).to be(true), "#{file} reads #{key.inspect}, which is below none of #{scopes.inspect} in en.yml."
      end
    end
  end
end
