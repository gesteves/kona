require 'httparty'
require 'uri'
require 'securerandom'
require 'json'
require 'active_support/all'
require 'redis'

# Utility class to handle Whoop OAuth 2.0 flow
class WhoopOAuth
  AUTH_URL = 'https://api.prod.whoop.com/oauth/oauth2/auth'
  TOKEN_URL = 'https://api.prod.whoop.com/oauth/oauth2/token'

  def initialize
    @client_id = ENV['WHOOP_CLIENT_ID']
    @client_secret = ENV['WHOOP_CLIENT_SECRET']
    @redirect_uri = ENV['WHOOP_REDIRECT_URI'] || 'http://localhost:3000/callback'
    
    # Initialize Redis connection
    @redis = Redis.new(
      host: ENV['REDIS_HOST'] || 'localhost',
      port: ENV['REDIS_PORT'] || 6379,
      username: ENV['REDIS_USERNAME'],
      password: ENV['REDIS_PASSWORD']
    )
    
    if @client_id.blank? || @client_secret.blank?
      puts "❎ Missing required environment variables:"
      puts "   WHOOP_CLIENT_ID - Your app's client ID from WHOOP Developer Dashboard"
      puts "   WHOOP_CLIENT_SECRET - Your app's client secret from WHOOP Developer Dashboard" 
      puts "   WHOOP_REDIRECT_URI - Your redirect URI (optional, defaults to http://localhost:3000/callback)"
      exit 1
    end
  end

  def get_authorization_url
    state = SecureRandom.hex(4) # 8 character state parameter
    
    params = {
      client_id: @client_id,
      response_type: 'code',
      scope: 'offline read:recovery read:cycles read:workout read:sleep read:profile read:body_measurement',
      redirect_uri: @redirect_uri,
      state: state
    }
    
    url = "#{AUTH_URL}?" + URI.encode_www_form(params)
    
    puts "🔗 Opening authorization URL in your browser..."
    puts url
    
    # Open URL in default browser
    system("open", url)
    
    puts
    puts "📝 After authorization, you'll be redirected to:"
    puts "   #{@redirect_uri}?code=AUTHORIZATION_CODE&state=#{state}"
    puts
    puts "📋 Copy the authorization code and paste it here:"
    print "Authorization code: "
    
    { url: url, state: state }
  end

  def exchange_code_for_tokens(authorization_code)
    puts "\n🔄 Exchanging authorization code for tokens..."
    
    params = {
      client_id: @client_id,
      client_secret: @client_secret,
      code: authorization_code,
      grant_type: 'authorization_code',
      redirect_uri: @redirect_uri
    }

    response = HTTParty.post(
      TOKEN_URL,
      body: params,
      headers: { 'Content-Type' => 'application/x-www-form-urlencoded' }
    )

    if response.success?
      access_token_key = "whoop:#{@client_id}:access_token"
      refresh_token_key = "whoop:#{@client_id}:refresh_token"
      token_data = JSON.parse(response.body, symbolize_names: true)
      
      # Store tokens in Redis
      access_token = token_data[:access_token]
      refresh_token = token_data[:refresh_token]
      expires_in = token_data[:expires_in] || 3600
      
      # Store access token with expiration (5 minute buffer)
      access_cache_duration = [expires_in - 300, 300].max
      @redis.setex(access_token_key, access_cache_duration, access_token)
      
      # Store refresh token (no expiration since we don't know when it expires)
      @redis.set(refresh_token_key, refresh_token)
      
      puts "✅ Success! Tokens stored in Redis:"
      puts
      puts "Access Token: #{access_token[0..20]}... (expires in #{expires_in} seconds)"
      puts "Refresh Token: #{refresh_token[0..20]}... (stored permanently)"
      puts "Scope: #{token_data[:scope]}"
      puts
      puts "🎉 Tokens are now stored in Redis and ready for use!"
      puts "   Redis keys:"
      puts "   - whoop:access_token (expires in #{access_cache_duration} seconds)"
      puts "   - whoop:refresh_token (permanent)"
      puts
      
      token_data
    else
      puts "❌ Error exchanging code for tokens:"
      puts "Status: #{response.code}"
      puts "Body: #{response.body}"
      nil
    end
  rescue => e
    puts "❌ Error: #{e.message}"
    nil
  end

  def run
    puts "Whoop OAuth 2.0 Setup"
    puts "=" * 50
    puts
    
    get_authorization_url
    authorization_code = STDIN.gets.chomp
    
    if authorization_code.empty?
      puts "❎ No authorization code provided. Exiting."
      return
    end
    
    # Step 3: Exchange code for tokens
    tokens = exchange_code_for_tokens(authorization_code)
    
    if tokens && tokens[:refresh_token]
      puts "🎉 Setup complete! You can now use the Whoop API."
    else
      puts "❎ Failed to get refresh token. Please try again."
    end
  end
end

