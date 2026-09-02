# Restart your server after you change this file.

# Give the parameter names that a part of a name matches, for example passw matches password, and
# that Rails removes from the log file.
# Use this to keep secret data out of the log.
# Refer to the ActiveSupport::ParameterFilter documentation for the syntax and the behavior.
# Bugsnag reads this same list. `calendar_url` is the TrainerRoad credential, `code` and `state` are
# the OAuth callback values, and `name` and `message` are the contact-form text of a visitor.
Rails.application.config.filter_parameters += [
  :passw, :email, :secret, :token, :_key, :crypt, :salt, :certificate, :otp, :ssn, :cvv, :cvc,
  :calendar_url, :code, :state, :name, :message
]
