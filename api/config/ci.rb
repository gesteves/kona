# Run using bin/ci
#
# ⚠️ GitHub runs these same gates, but split across the `ruby-tests` and `security` jobs in
# .github/workflows/api.yml so they go in parallel — nothing keeps the two lists in sync. A step
# added here has to be added there too, or it only ever runs locally.

CI.run do
  step "Setup", "bin/setup --skip-server"

  # ⚠️ Must precede rspec: /signin renders through layouts/auth, and Propshaft raises
  # MissingAssetError when the esbuild output isn't there. bin/setup installs the packages.
  step "Assets: esbuild", "npm run build"

  step "Tests: RSpec", "bundle exec rspec"

  step "Style: RuboCop", "bundle exec rubocop --no-color"
  step "Security: Brakeman", "bundle exec brakeman -q --no-pager"
  step "Audit: bundler-audit", "bundle exec bundle-audit check --update"
end
