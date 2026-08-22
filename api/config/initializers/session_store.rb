# The owner session. Each value here but `expire_after` is the Rails default for a cookie store:
# encrypted and signed, HttpOnly, SameSite=Lax, and `secure` in production through `force_ssl`. They
# are here only because a declaration of the store replaces each default value.
#
# ⚠️ `expire_after` is the reason for this file. A cookie session has no record on the server, thus
# there is nothing to remove: without a new `secret_key_base`, a cookie that an attacker takes works
# until the browser removes it, and for a session cookie that can be a very long time. This value
# gives a maximum.
Rails.application.config.session_store :cookie_store,
  key: "_api_session",
  same_site: :lax,
  expire_after: 2.weeks
