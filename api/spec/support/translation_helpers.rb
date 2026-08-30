# Helpers to assert admin copy without writing the words in a spec.
#
# ⚠️ Each user-facing word of the admin is in config/locales/en.yml. Thus a spec asserts
# `I18n.t("admin.…")` and never the words, and a change to a word breaks no spec.
module TranslationHelpers
  # A character that no translation holds, thus a split on it is safe.
  SENTINEL = "\u0000".freeze

  # The text of a key BEFORE one of its interpolations.
  #
  # Use it where the interpolated value is the thing that the spec must prove — a date that the
  # code formats, or a count that it works out — and the words around that value are copy. The
  # spec then asserts `"#{t_before(...)}August 20, 2026"`, thus it proves the value and it still
  # reads the words from the locale file.
  #
  # @param key [String] The translation key.
  # @param placeholder [Symbol] The name of the interpolation to stop at.
  # @param options [Hash] Each other interpolation that the key needs.
  # @return [String] The words that come before that interpolation.
  def t_before(key, placeholder, **options)
    I18n.t(key, **options, placeholder => SENTINEL).split(SENTINEL).first
  end
end

RSpec.configure do |config|
  config.include TranslationHelpers
end
