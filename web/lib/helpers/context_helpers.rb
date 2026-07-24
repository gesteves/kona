module ContextHelpers
  # The deploy context this build runs in — "production" for the real public site,
  # anything else (or unset) for local development. Set explicitly in the build env; see
  # .github/workflows/web.yml.
  # @return [String, nil] The current deploy context.
  def deploy_context
    ENV['DEPLOY_CONTEXT'].presence
  end

  # Determines if this build is the real public site (as opposed to local dev).
  # @return [Boolean] True if this is a production build.
  def production?
    deploy_context == 'production'
  end
end
