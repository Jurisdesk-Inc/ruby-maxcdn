require "signet/oauth_1/client"
require "curb-fu"
require "json"

module MaxCDN
  module Utils
    RESERVED_CHARACTERS = /[^a-zA-Z0-9\-\.\_\~]/

    def escape(value)
      URI::escape(value.to_s, MaxCDN::Utils::RESERVED_CHARACTERS)
    rescue ArgumentError
      URI::escape(value.to_s.force_encoding(Encoding::UTF_8), MaxCDN::Utils::RESERVED_CHARACTERS)
    end

    def encode_params params={}
      Hash[params.map { |k, v| [escape(k), escape(v)] }]
    end
  end

  class APIException < Exception
  end

  class Client
    include MaxCDN::Utils

    attr_accessor :client
    def initialize(company_alias, key, secret, server="rws.maxcdn.com", secure_connection=true)
      @company_alias = company_alias
      @server = server
      @secure_connection = secure_connection
      @request_signer = Signet::OAuth1::Client.new(
        :client_credential_key => key,
        :client_credential_secret => secret,
        :two_legged => true
      )
    end

    def _connection_type
      return "http" unless @secure_connection
      "https"
    end

    def _encode_params params={}
      encode_params(params).map { |k, v|
        "#{k}=#{v}"
      }.join "&"
    end

    def _get_url uri, params={}

      url = "#{_connection_type}://#{@server}/#{@company_alias}/#{uri.gsub(/^\//, "")}"
      if not params.empty?
        url += "?#{_encode_params(params)}"
      end

      url
    end

    def _response_as_json method, uri, options={}, *attributes
      if options.delete(:debug)
        puts "Making #{method.upcase} request to #{_get_url uri}"
      end

      request_options = {
        :uri => _get_url(uri, options[:body] ? attributes[0] : {}),
        :method => method
      }

      request_options[:body] = _encode_params(attributes[0]) if options[:body]
      request = @request_signer.generate_authenticated_request(request_options)
      request.headers["User-Agent"] = "Ruby MaxCDN API Client"

      begin
        curb_options = {}
        curb_options[:url] = request_options[:uri]
        curb_options[:headers] = request.headers

        if not options[:body]
          response = CurbFu.send method, curb_options
        else
          response = CurbFu.send method, curb_options, request.body
        end

        return response if options[:debug_request]

        response_json = JSON.load(response.body)

        return response_json if options[:debug_json]

        if not (response.success? or response.redirect?)
          error_message = response_json["error"]["message"]
          raise MaxCDN::APIException.new("#{response.status}: #{error_message}")
        end
      rescue TypeError
        raise MaxCDN::APIException.new(
          "#{response.status}: No information supplied by the server"
        )
      end

      response_json
    end

    [ :get, :post, :put, :delete ].each do |meth|
      define_method(meth) do |uri, data={}, options={}|
        options[:body] = false
        self._response_as_json meth.to_s, uri, options, data
      end
    end

    def purge zone_id, file_or_files=nil, options={}
      unless file_or_files.nil?
        return self.delete(
          "/zones/pull.json/#{zone_id}/cache",
          {"file" => file_or_files},
            options
        )
      end

      self.delete("/zones/pull.json/#{zone_id}/cache", {}, options)
    end
  end
end