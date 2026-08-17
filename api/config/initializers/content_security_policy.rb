# Nonce plumbing for the owner-facing pages' Content-Security-Policy.
#
# ⚠️ No default policy is declared here, deliberately. The policy itself lives in the OwnerFacing
# concern, so it lands on the admin UI and the sign-in page and nowhere else. A global default would
# put a CSP header on every widget fragment — machine-read markup that no browser treats as a
# document — and that header would then be stored in the edge cache alongside the fragment.
#
# ⚠️ script-src only. A nonce in a directive makes browsers ignore `unsafe-inline` in that same
# directive (CSP3), and OwnerFacing's style-src needs `unsafe-inline` for the styles Web Awesome and
# Mapbox GL JS inject at runtime. Adding style-src back here would silently break every component.
Rails.application.config.content_security_policy_nonce_generator = ->(_request) { SecureRandom.base64(16) }
Rails.application.config.content_security_policy_nonce_directives = %w[script-src]
