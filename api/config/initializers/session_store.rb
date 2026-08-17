# The owner session. Everything but `expire_after` is Rails' implicit default for a cookie store —
# encrypted and signed, HttpOnly, SameSite=Lax, and `secure` in production via `force_ssl` — and is
# restated here only because declaring the store at all replaces that default wholesale.
#
# ⚠️ `expire_after` is the reason this file exists. A cookie session has no server-side record, so
# there is nothing to revoke: short of rotating `secret_key_base`, a stolen cookie is valid until
# the browser discards it, which for a session cookie may be never. This gives it a ceiling.
Rails.application.config.session_store :cookie_store,
  key: "_api_session",
  same_site: :lax,
  expire_after: 2.weeks
