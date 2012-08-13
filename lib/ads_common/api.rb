# Encoding: utf-8
#
# Authors:: api.dklimkin@gmail.com (Danial Klimkin)
#
# Copyright:: Copyright 2010, Google Inc. All Rights Reserved.
#
# License:: Licensed under the Apache License, Version 2.0 (the "License");
#           you may not use this file except in compliance with the License.
#           You may obtain a copy of the License at
#
#           http://www.apache.org/licenses/LICENSE-2.0
#
#           Unless required by applicable law or agreed to in writing, software
#           distributed under the License is distributed on an "AS IS" BASIS,
#           WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
#           implied.
#           See the License for the specific language governing permissions and
#           limitations under the License.
#
# Generic API class, to be inherited from and extended by specific APIs.

require 'logger'

require 'ads_common/config'
require 'ads_common/errors'
require 'ads_common/utils'
require 'ads_common/auth/client_login_handler'
require 'ads_common/auth/oauth_handler'
require 'ads_common/auth/oauth2_handler'

module AdsCommon
  class Api

    # Methods that return the client library configuration. Needs to be
    # redefined in subclasses.
    attr_reader :config

    # Credential handler objects used for authentication.
    attr_reader :credential_handler

    # The logger for this API object.
    attr_reader :logger

    # Constructor for API.
    def initialize(provided_config = nil)
      @wrappers = {}
      load_config(provided_config)
    end

    # Sets the logger to use.
    def logger=(logger)
      @logger = logger
      @config.set('library.logger', @logger)
    end

    # Getter for the API service configurations.
    def api_config()
      return AdsCommon::ApiConfig
    end

    # Obtain an API service, given a version and its name.
    #
    # Args:
    # - name: name for the intended service
    # - version: intended API version.
    #
    # Returns:
    # - the service wrapper for the intended service.
    #
    def service(name, version = nil)
      name = name.to_sym
      version = (version.nil?) ? api_config.default_version : version.to_sym
      environment = @config.read('service.environment')

      # Check if the combination is available.
      validate_service_request(environment, version, name)

      # Try to re-use the service for this version if it was requested before.
      wrapper = if @wrappers.include?(version) && @wrappers[version][name]
        @wrappers[version][name]
      else
        @wrappers[version] ||= {}
        @wrappers[version][name] = prepare_wrapper(version, name)
      end
      return wrapper
    end

    # Authorize with specified authentication method.
    #
    # Args:
    #  - parameters - hash of credentials to add to configuration
    #  - block - code block to handle auth login url
    #
    # Returns:
    #  - Auth token for the method
    #
    # Throws:
    #  - AdsCommon::Errors::AuthError or derived if authetication error has
    #    occured
    #
    def authorize(parameters = {}, &block)
      parameters.each_pair do |key, value|
        @credential_handler.set_credential(key, value)
      end

      auth_handler = get_auth_handler()
      token = auth_handler.get_token()

      # If token is invalid ask for a new one.
      if token.nil?
        begin
          credentials = @credential_handler.credentials
          token = @auth_handler.get_token(credentials)
        rescue AdsCommon::Errors::OAuthVerificationRequired,
            AdsCommon::Errors::OAuth2VerificationRequired => e
          verification_code = (block_given?) ? yield(e.oauth_url) : nil
          # Retry with verification code if one provided.
          if verification_code
            code_symbol =
                e.kind_of?(AdsCommon::Errors::OAuthVerificationRequired) ?
                :oauth_verification_code : :oauth2_verification_code
            @credential_handler.set_credential(code_symbol, verification_code)
            retry
          else
            raise e
          end
        end
      end
      return token
    end

    # Auxiliary method to get an authentication handler. Creates a new one if
    # the handler has not been initialized yet.
    #
    # Returns:
    # - auth handler
    #
    def get_auth_handler()
      if @auth_handler.nil?
        @auth_handler = create_auth_handler()
        @credential_handler.set_auth_handler(@auth_handler)
      end
      return @auth_handler
    end

    private

    # Auxiliary method to test parameters correctness for the service request.
    def validate_service_request(environment, version, service)
      # Check if the current environment supports the requested version.
      unless api_config.environment_has_version(environment, version)
        raise AdsCommon::Errors::Error,
            "Environment '%s' does not support version '%s'" %
            [environment.to_s, version.to_s]
      end

      # Check if the specified version has the requested service.
      unless api_config.version_has_service(version, service)
        raise AdsCommon::Errors::Error,
            "Version '%s' does not contain service '%s'" %
            [version.to_s, service.to_s]
      end
    end

    # Retrieve the SOAP header handler to generate headers based on the
    # configuration. Needs to be implemented on the specific API, because of
    # the different types of SOAP headers.
    #
    # Args:
    # - auth_handler: instance of an AdsCommon::Auth::BaseHandler subclass to
    #   handle authentication
    # - version: intended API version
    # - header_ns: header namespace
    # - default_ns: default namespace
    #
    # Returns:
    # - a SOAP header handler
    #
    def soap_header_handler(auth_handler, version, header_ns, default_ns)
      raise NotImplementedError, 'soap_header_handler not overridden.'
    end

    # Auxiliary method to create an authentication handler.
    #
    # Returns:
    # - auth handler
    #
    def create_auth_handler()
      auth_method = @config.read('authentication.method', :CLIENTLOGIN)
      return case auth_method
        when :CLIENTLOGIN
          AdsCommon::Auth::ClientLoginHandler.new(
              @config,
              api_config.client_login_config(:AUTH_SERVER),
              api_config.client_login_config(:LOGIN_SERVICE_NAME)
          )
        when :OAUTH
          environment = @config.read('service.environment',
              api_config.default_environment())
          AdsCommon::Auth::OAuthHandler.new(
              @config,
              api_config.environment_config(environment, :oauth_scope)
          )
        when :OAUTH2
          environment = @config.read('service.environment',
              api_config.default_environment())
          AdsCommon::Auth::OAuth2Handler.new(
              @config,
              api_config.environment_config(environment, :oauth_scope)
          )
        else
          raise AdsCommon::Errors::Error,
              "Unknown authentication method '%s'" % auth_method
        end
    end

    # Handle loading of a single service.
    # Creates the wrapper, sets up handlers and creates an instance of it.
    #
    # Args:
    # - version: intended API version, must be a symbol
    # - service: name for the intended service
    #
    # Returns:
    # - a simplified wrapper generated for the service
    #
    def prepare_wrapper(version, service)
      environment = config.read('service.environment')
      api_config.do_require(version, service)
      endpoint = api_config.endpoint(environment, version, service)
      interface_class_name = api_config.interface_name(version, service)

      wrapper = class_for_path(interface_class_name).new(@config, endpoint)
      auth_handler = get_auth_handler()
      header_ns =
          api_config.environment_config(environment, :header_ns) + version.to_s
      soap_handler = soap_header_handler(auth_handler, version, header_ns,
                                         wrapper.namespace)
      wrapper.header_handler = soap_handler

      return wrapper
    end

    # Auxiliary method to create a default Logger.
    def create_default_logger()
      logger = Logger.new(STDOUT)
      logger.level = get_log_level_for_string(
          @config.read('library.log_level', 'INFO'))
      return logger
    end

    # Helper method to load the default configuration file or a given config.
    def load_config(provided_config = nil)
      @config = (provided_config.nil?) ?
          AdsCommon::Config.new(
              File.join(ENV['HOME'], api_config.default_config_filename)) :
          AdsCommon::Config.new(provided_config)
      init_config()
    end

    # Initializes config with default values and converts existing if required.
    def init_config()
      # Set up logger.
      provided_logger = @config.read('library.logger')
      self.logger = (provided_logger.nil?) ?
          create_default_logger() : provided_logger

      # Validating most important parameters.
      ['service.environment', 'authentication.method'].each do |parameter|
        symbolize_config_value(parameter)
      end
    end

    # Converts value of a config key to uppercase symbol.
    def symbolize_config_value(key)
      value_str = @config.read(key).to_s
      if !value_str.nil? and !value_str.empty?
        value = value_str.upcase.to_sym
        @config.set(key, value)
      end
    end

    # Converts log level string (from config) to Logger value.
    def get_log_level_for_string(log_level)
      return Logger.const_get(log_level)
    end

    # Converts complete class path into class object.
    def class_for_path(path)
      path.split('::').inject(Kernel) do |scope, const_name|
        scope.const_get(const_name)
      end
    end
  end
end
