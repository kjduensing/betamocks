# frozen_string_literal: true

require 'yaml'

module Betamocks
  class Configuration
    attr_accessor :cache_dir, :mocked_endpoints, :services_config
    attr_writer :recording, :enabled

    DISTANCE_CUTOFF = 10

    def find_endpoint(env)
      service = service_by_host_port(env)
      return nil unless service
      # TODO raise if service.size > 1 ?
      
      endpoints = service[:endpoints].select { |e| matches_path(e, env.method, env.url.path) }
      return nil unless endpoints
      return endpoints.first if endpoints.size == 1

      # one path + http verb may be used for multiple resources
      endpoints = endpoints.select { |e| matches_request_params(e, env) }
      return nil unless endpoints
      return endpoints.first if endpoints.size == 1

      byebug
      close_matches = closest_matches(service[:endpoints], env)

      close_matches_strs = close_matches.map do |m|
        "    \033[34m#{m[:method].upcase} #{m[:path]}\033[0m"
      end

      no_match_msg = "\n\n\033[31mBetamocks Error: Unable to uniquely identify request!\033[0m"
      no_match_msg += "\n  \033[33mRequest: #{env.method.upcase} #{env.url.to_s}\033[0m"
      no_match_msg += "\n\n  Closest matches: \n#{close_matches_strs.join("\n")}"
      no_match_msg += "\n\nIf you expected a match and you see an exact match on method and path in the list above"
      no_match_msg += ", check the parameters of the request against the parameters defined in services_config.yml.\n"

      raise ArgumentError, no_match_msg
    end

    def config
      @config ||= load_config
    end

    def enabled=(value)
      @enabled = value.to_s == 'true'
    end

    def recording=(value)
      @recording = value.to_s == 'true'
    end

    def enabled?
      return false if [ENV['RAILS_ENV'], ENV['RACK_ENV']].include? 'test'
      @enabled
    end

    def recording?
      @recording || false
    end

    private

    def load_config
      raise ArgumentError, 'config.services_config not set' unless @services_config
      raise IOError, 'config.services_config file not found' unless File.exist? @services_config
      YAML.load(ERB.new(File.read(@services_config)).result)
    end

    def base_urls
      @base_urls ||= config[:services].map { |s| s[:base_urls] }.flatten
    end

    def service_by_host_port(env)
      config[:services].select { |s| s[:base_uri] == "#{env.url.host}:#{env.url.port}" }.first
    end

    def matches_path(endpoint, method, path)
      replacement_map = {
        '/' => '\/',
        '(' => '\(',
        ')' => '\)',
        '*' => '[^\/]*'
      }

      endpoint_path = endpoint[:path]
      replacement_map.each_pair do |original, replacement|
        endpoint_path = endpoint_path.gsub(original, replacement)
      end

      /\A#{endpoint_path}\z/ =~ path && endpoint[:method] == method
    end

    def matches_request_params(endpoint, env)
      endpoint_config = endpoint.dig(:cache_multiple_responses)
      return false if endpoint_config.nil?

      location = endpoint_config[:uid_location].to_sym
      locator = endpoint_config[:uid_locator]

      optional_locator = endpoint_config[:optional_code_locator]

      case location
      when :body
        /#{locator}/ =~ env.body && /#{optional_locator}/ =~ env.body
      when :header
        return false # TODO
      when :query
        return false # TODO
      when :url
        return false # TODO
      else
        message = "#{location} is not a valid location for a uid try 'body', 'headers', 'query', or 'url' instead"
        raise ArgumentError, message
      end
    end

    def get_path_distance(endpoint, env)
      # Match on path first
      DidYouMean::Levenshtein.distance(env.path, endpoint[:path])
    end

    def closest_matches(endpoints, request)
      paths_w_distance = endpoints.reduce([]) do |acc, endpoint|
        method_distance = DidYouMean::Levenshtein.distance(request.method.to_s, endpoint[:method].to_s)
        path_distance = DidYouMean::Levenshtein.distance(request.url.path, endpoint[:path])
        acc.append({
          distance: method_distance + path_distance,
          method: endpoint[:method].to_s,
          path: endpoint[:path]
        })
      end

      lowest_three = paths_w_distance.min_by(3) { |p| p[:distance] }

      # Filter the list down to the most similar options
      lowest_three.select { |p| p[:distance] - lowest_three[0][:distance] <= DISTANCE_CUTOFF }
    end
  end
end
