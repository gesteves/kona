module ContextHelpers
  # @return [String, nil] The deploy context, from the build environment.
  def deploy_context
    ENV["DEPLOY_CONTEXT"].presence
  end

  # @return [Boolean] True if this build is the true public site.
  def production?
    deploy_context == "production"
  end
end
