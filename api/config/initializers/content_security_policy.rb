# The nonce code for the Content-Security-Policy of the pages of the owner.
#
# ⚠️ There is no default policy here, on purpose. The policy is in the OwnerFacing concern, thus it
# applies to the admin UI and to the sign-in page, and to nothing else. A global default would put a
# CSP header on each widget fragment. A fragment is markup for a machine and no browser reads it as
# a document, and the edge cache would then hold that header with the fragment.
#
# ⚠️ The nonce applies to script-src only. A nonce in a directive makes a browser ignore
# `unsafe-inline` in that same directive (CSP3), and the style-src of OwnerFacing needs
# `unsafe-inline` for the styles that Web Awesome and Mapbox GL JS write at run time. style-src here
# would stop each component, and give no message.
Rails.application.config.content_security_policy_nonce_generator = ->(_request) { SecureRandom.base64(16) }
Rails.application.config.content_security_policy_nonce_directives = %w[script-src]
