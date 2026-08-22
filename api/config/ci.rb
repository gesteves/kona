# Run this with bin/ci.
#
# ⚠️ GitHub runs the same checks, but in two jobs in .github/workflows/api.yml, `ruby-tests` and
# `security`, thus they run at the same time. Nothing keeps the two lists the same. Add each new
# step here to that file also, or it runs on your own machine only.

CI.run do
  step "Setup", "bin/setup --skip-server"

  # ⚠️ This must come before rspec. /signin renders through layouts/auth, and Propshaft raises
  # MissingAssetError when the esbuild output is absent. bin/setup installs the packages.
  step "Assets: esbuild", "npm run build"

  step "Tests: RSpec", "bundle exec rspec"

  step "Style: RuboCop", "bundle exec rubocop --no-color"
  step "Security: Brakeman", "bundle exec brakeman -q --no-pager"
  step "Audit: bundler-audit", "bundle exec bundle-audit check --update"
end
