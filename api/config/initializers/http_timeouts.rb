require "httparty"

# The default connect timeout and read timeout of each upstream HTTP call. Each service calls its
# API through the module-level HTTParty methods, and those go through HTTParty::Basement. Thus the
# defaults here apply to each call site, from one place.
#
# Without this file, each call uses the Net::HTTP defaults of approximately 60s, and two upstream
# services that stop would use all three Puma threads. That is worse with with_retries, where a stop
# is not an error until those 60s end. rack_timeout.rb is the limit of the full request, and this
# file is the limit of each call. An option on one call still wins.
HTTParty::Basement.open_timeout 5
HTTParty::Basement.read_timeout 10
