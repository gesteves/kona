require 'redis'

# Wraps a Redis client so transient connection failures or timeouts don't
# abort the build. Reads return nil (cache miss), writes are dropped, and
# mget returns an array of nils. Once a connection error is observed the
# client is marked unavailable for the rest of the process, so subsequent
# calls short-circuit instead of paying the connect timeout each time.
class SafeRedis
  RESCUABLE_ERRORS = [Redis::BaseConnectionError].freeze

  def initialize(**options)
    @client = Redis.new(**options)
    @available = true
  end

  def available?
    @available
  end

  def mget(*keys)
    flat_keys = keys.flatten
    return Array.new(flat_keys.length) unless @available
    @client.mget(*flat_keys)
  rescue *RESCUABLE_ERRORS => e
    mark_unavailable(:mget, e)
    Array.new(flat_keys.length)
  end

  def respond_to_missing?(name, include_private = false)
    @client.respond_to?(name, include_private) || super
  end

  def method_missing(name, *args, **kwargs, &block)
    return nil unless @available
    @client.public_send(name, *args, **kwargs, &block)
  rescue *RESCUABLE_ERRORS => e
    mark_unavailable(name, e)
    nil
  end

  private

  def mark_unavailable(method, error)
    @available = false
    warn "⚠️  Redis unavailable during #{method} (#{error.class}: #{error.message}); continuing without cache."
  end
end
