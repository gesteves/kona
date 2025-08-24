require_relative '../data/whoop'

# Utility class to handle Whoop OAuth 2.0 flow
class WhoopOAuth
  def initialize
    @whoop = Whoop.new
    
    unless @whoop.valid_credentials?
      puts "❎ Missing required environment variables:"
      puts "   WHOOP_CLIENT_ID - Your app's client ID from WHOOP Developer Dashboard"
      puts "   WHOOP_CLIENT_SECRET - Your app's client secret from WHOOP Developer Dashboard" 
      puts "   WHOOP_REDIRECT_URI - Your redirect URI"
      exit 1
    end
  end

  def get_authorization_url
    auth_data = @whoop.get_authorization_url
    return unless auth_data
    
    url = auth_data[:url]
    state = auth_data[:state]
    redirect_uri = auth_data[:redirect_uri]
    
    puts "🔗 Opening authorization URL in your browser..."
    puts url
    
    # Open URL in default browser
    system("open", url)
    
    puts
    puts "📝 After authorization, you'll be redirected to:"
    puts "   #{redirect_uri}?code=AUTHORIZATION_CODE&state=#{state}"
    puts
    puts "📋 Copy the authorization code and paste it here:"
    print "Authorization code: "
    
    auth_data
  end

  def exchange_code_for_tokens(authorization_code)
    puts "\n🔄 Exchanging authorization code for tokens..."
    
    token_data = @whoop.exchange_code_for_tokens(authorization_code)
    
    if token_data
      access_token = token_data[:access_token]
      refresh_token = token_data[:refresh_token]
      expires_in = token_data[:expires_in] || 3600
      access_cache_duration = [expires_in - 300, 300].max
      client_id = ENV['WHOOP_CLIENT_ID']
      
      puts "✅ Success! Tokens stored in Redis:"
      puts
      puts "Access Token: #{access_token[0..20]}... (expires in #{expires_in} seconds)"
      puts "Refresh Token: #{refresh_token[0..20]}... (stored permanently)"
      puts "Scope: #{token_data[:scope]}"
      puts
      puts "🎉 Tokens are now stored in Redis and ready for use!"
      puts "   Redis keys:"
      puts "   - whoop:#{client_id}:access_token (expires in #{access_cache_duration} seconds)"
      puts "   - whoop:#{client_id}:refresh_token (permanent)"
      puts
      
      token_data
    else
      puts "❌ Error exchanging code for tokens"
      nil
    end
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

