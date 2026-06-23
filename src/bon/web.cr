require "ecr"
require "html"
require "http/formdata"
require "json"
require "kemal"

require "./config"
require "./cups"
require "./document"
require "./print_job"

module Bon
  module Web
    DEFAULT_HOST          = "0.0.0.0"
    DEFAULT_PORT          = 8080
    DEFAULT_MAX_UPLOAD_MB =   25

    struct Options
      property host : String
      property port : Int32
      property token : String?
      property max_upload_bytes : Int64

      def initialize(@host = DEFAULT_HOST, @port = DEFAULT_PORT, @token = nil.as(String?), @max_upload_bytes = DEFAULT_MAX_UPLOAD_MB.to_i64 * 1024 * 1024)
      end

      def token_configured? : Bool
        token = @token
        !!(token && !token.empty?)
      end
    end

    def self.run(options : Options, output_io : IO = STDOUT, error_io : IO = STDERR) : Nil
      app = Application.new(options, output_io, error_io)
      Application.current = app
      Application.register_routes

      Kemal.config.app_name = "bon"
      Kemal.config.host_binding = options.host
      Kemal.config.port = options.port
      Kemal.config.logging = false
      Kemal.config.serve_static = false
      Kemal.config.powered_by_header = false
      Kemal.config.max_request_body_size = options.max_upload_bytes.to_i32
      output_io.puts("bon web listening on http://#{options.host}:#{options.port}")
      Kemal.run(args: nil)
    end

    class Application
      @@current = nil.as(Application?)
      @@routes_registered = false
      @print_lock = Mutex.new

      def self.current=(application : Application) : Nil
        @@current = application
      end

      def self.current : Application
        @@current || raise Error.new("Web application is not configured")
      end

      def self.register_routes : Nil
        return if @@routes_registered

        get "/" do |env|
          current.serve_form(env)
        end

        get "/health" do |env|
          current.text(env, 200, "ok\n")
        end

        post "/print" do |env|
          current.handle_print(env)
        end

        ["/", "/health", "/print"].each do |path|
          post(path) { |env| current.method_not_allowed(env) } unless path == "/print"
          put(path) { |env| current.method_not_allowed(env) }
          patch(path) { |env| current.method_not_allowed(env) }
          delete(path) { |env| current.method_not_allowed(env) }
          options(path) { |env| current.method_not_allowed(env) }
        end

        error 404 do |env, _ex|
          current.error(env, 404, "not found")
        end

        error 413 do |env, _ex|
          current.too_large(env, current.browser_html?(env.request))
        end

        error Error do |env, ex|
          current.error(env, 500, ex.message || "print failed", current.browser_html?(env.request))
        end

        @@routes_registered = true
      end

      def initialize(@options : Options, @output_io : IO = STDOUT, @error_io : IO = STDERR)
      end

      def self.test_server(options = Options.new(host: "127.0.0.1", port: 0), output_io : IO = IO::Memory.new, error_io : IO = IO::Memory.new) : HTTP::Server
        self.current = new(options, output_io, error_io)
        register_routes
        Kemal.config.max_request_body_size = options.max_upload_bytes.to_i32
        HTTP::Server.new([Kemal::ExceptionHandler.new, Kemal::RouteHandler::INSTANCE] of HTTP::Handler)
      end

      def serve_form(env : HTTP::Server::Context) : String
        html(env, 200, render_form)
      end

      def handle_print(env : HTTP::Server::Context) : String
        wants_html = browser_html?(env.request)
        return too_large(env, wants_html) if declared_too_large?(env.request)

        content_type = env.request.headers["Content-Type"]?
        unless content_type && content_type.starts_with?("multipart/form-data")
          return error(env, 415, "expected multipart/form-data", wants_html)
        end

        PrintJob.with_temp_dir("bon-web-") do |temp_dir|
          token_field = nil.as(String?)
          files = [] of String
          bytes_read = [0_i64]

          HTTP::FormData.parse(env.request) do |part|
            name = part.name
            filename = part.filename
            if @options.token_configured? && name == "token" && !filename
              token_field = read_part(part.body, @options.max_upload_bytes, bytes_read)
              next
            end
            next unless (name == "file" || name == "files[]") && filename

            basename = sanitized_basename(filename, files.size + 1)
            ext = File.extname(basename).downcase
            unless Document::SUPPORTED_SUFFIXES.includes?(ext)
              return error(env, 400, "unsupported upload type: #{basename}", wants_html)
            end

            path = File.join(temp_dir, "#{(files.size + 1).to_s.rjust(3, '0')}-#{basename}")
            size = write_part(part.body, path, @options.max_upload_bytes, bytes_read)
            return error(env, 400, "empty upload: #{basename}", wants_html) if size == 0
            files << path
          end

          return unauthorized(env, wants_html) unless authorized?(env.request, token_field)
          return error(env, 400, "no uploads provided", wants_html) if files.empty?

          @print_lock.synchronize do
            loaded = Config.load_with_sources
            emit_config_warnings(loaded)
            config = loaded.config
            config.validate!
            queue = Cups.discover(config)
            config.apply_printer_overrides!(queue.name)
            config.validate!
            PrintJob.run(files, queue.name, config, false, Hash(String, String).new, @output_io, @error_io)
          end

          message = "submitted #{files.size} file(s)"
          return success(env, files.size, message, wants_html)
        end
      rescue ex : UploadTooLarge | Kemal::Exceptions::PayloadTooLarge
        too_large(env, browser_html?(env.request))
      end

      def method_not_allowed(env : HTTP::Server::Context) : String
        error(env, 405, "method not allowed")
      end

      def too_large(env : HTTP::Server::Context, wants_html : Bool) : String
        error(env, 413, "upload too large", wants_html)
      end

      def error(env : HTTP::Server::Context, status : Int32, message : String, wants_html : Bool = false) : String
        if wants_html
          html(env, status, render_result(false, message))
        else
          json(env, status) do |json|
            json.object do
              json.field "ok", false
              json.field "error", message
            end
          end
        end
      end

      def text(env : HTTP::Server::Context, status : Int32, body : String) : String
        env.response.status_code = status
        env.response.content_type = "text/plain; charset=utf-8"
        body
      end

      def html(env : HTTP::Server::Context, status : Int32, body : String) : String
        env.response.status_code = status
        env.response.content_type = "text/html; charset=utf-8"
        body
      end

      def browser_html?(request : HTTP::Request) : Bool
        accept = request.headers["Accept"]?
        !!(accept && accept.includes?("text/html"))
      end

      private def render_form : String
        token_configured = @options.token_configured?
        content = ECR.render("src/bon/web/templates/index.ecr")
        render_layout("bon print upload", content)
      end

      private def render_result(ok : Bool, message : String) : String
        title = ok ? "Print Submitted" : "Print Failed"
        escaped_message = HTML.escape(message)
        content = ECR.render("src/bon/web/templates/result.ecr")
        render_layout(title, content)
      end

      private def render_layout(title : String, content : String) : String
        ECR.render("src/bon/web/templates/layout.ecr")
      end

      private def declared_too_large?(request : HTTP::Request) : Bool
        if length = request.content_length
          return length > @options.max_upload_bytes
        end
        false
      end

      private def read_part(io : IO, max : Int64, bytes_read : Array(Int64)) : String
        memory = IO::Memory.new
        buffer = Bytes.new(8192)
        loop do
          read = io.read(buffer)
          break if read == 0
          bytes_read[0] += read
          raise UploadTooLarge.new if bytes_read[0] > max
          memory.write(buffer[0, read])
        end
        memory.to_s
      end

      private def write_part(io : IO, path : String, max : Int64, bytes_read : Array(Int64)) : Int64
        size = 0_i64
        File.open(path, "w") do |file|
          buffer = Bytes.new(8192)
          loop do
            read = io.read(buffer)
            break if read == 0
            bytes_read[0] += read
            raise UploadTooLarge.new if bytes_read[0] > max
            file.write(buffer[0, read])
            size += read
          end
        end
        size
      end

      private def authorized?(request : HTTP::Request, token_field : String?) : Bool
        expected = @options.token
        return true unless expected && !expected.empty?

        auth = request.headers["Authorization"]?
        return true if auth == "Bearer #{expected}"
        return true if request.headers["X-Bon-Token"]? == expected
        token_field == expected
      end

      private def sanitized_basename(filename : String, index : Int32) : String
        basename = File.basename(filename).gsub(/[\\\/]/, "")
        ext = File.extname(basename)
        return "upload-#{index}#{ext}" if basename.empty? || basename == "." || basename == ".."
        basename
      end

      private def emit_config_warnings(loaded : LoadedConfig) : Nil
        loaded.warnings.each { |warning| @error_io.puts("warning: #{warning}") }
      end

      private def success(env : HTTP::Server::Context, files : Int32, message : String, wants_html : Bool) : String
        if wants_html
          html(env, 200, render_result(true, message))
        else
          json(env, 200) do |json|
            json.object do
              json.field "ok", true
              json.field "files", files
              json.field "message", message
            end
          end
        end
      end

      private def unauthorized(env : HTTP::Server::Context, wants_html : Bool) : String
        env.response.headers["WWW-Authenticate"] = "Bearer"
        error(env, 401, "unauthorized", wants_html)
      end

      private def json(env : HTTP::Server::Context, status : Int32, &) : String
        env.response.status_code = status
        env.response.content_type = "application/json"
        JSON.build { |builder| yield builder }
      end
    end

    class UploadTooLarge < Exception
    end
  end
end
