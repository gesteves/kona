# Run using bin/ci

CI.run do
  step "Setup", "bin/setup --skip-server"

  step "Tests: RSpec", "bundle exec rspec"

  step "Security: Brakeman", "bundle exec brakeman -q --no-pager"
  step "Audit: bundler-audit", "bundle exec bundle-audit check --update"
end
