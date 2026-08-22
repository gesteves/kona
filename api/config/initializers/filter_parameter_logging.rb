# Restart your server after you change this file.

# Give the parameter names that a part of a name matches, for example passw matches password, and
# that Rails removes from the log file.
# Use this to keep secret data out of the log.
# Refer to the ActiveSupport::ParameterFilter documentation for the syntax and the behavior.
Rails.application.config.filter_parameters += [
  :passw, :email, :secret, :token, :_key, :crypt, :salt, :certificate, :otp, :ssn, :cvv, :cvc
]
