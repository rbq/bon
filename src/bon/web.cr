require "http/server"
require "http/formdata"
require "json"
require "html"

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
      server = HTTP::Server.new do |context|
        app.call(context)
      end
      address = server.bind_tcp(options.host, options.port)
      output_io.puts("bon web listening on http://#{options.host}:#{address.port}")
      server.listen
    end

    class Application
      @print_lock = Mutex.new

      def initialize(@options : Options, @output_io : IO = STDOUT, @error_io : IO = STDERR)
      end

      def call(context : HTTP::Server::Context) : Nil
        request = context.request
        case {request.method, request.path}
        when {"GET", "/"}
          serve_form(context)
        when {"GET", "/health"}
          text(context, 200, "ok\n")
        when {"POST", "/print"}
          handle_print(context)
        else
          if request.path == "/" || request.path == "/health" || request.path == "/print"
            error(context, 405, "method not allowed")
          else
            error(context, 404, "not found")
          end
        end
      rescue ex : Error
        error(context, 500, ex.message || "print failed")
      rescue ex : Exception
        @error_io.puts("error: #{ex.message}")
        error(context, 500, "internal server error")
      end

      private def serve_form(context : HTTP::Server::Context) : Nil
        token_input = if @options.token_configured?
                        %(<label>Token <input type="password" name="token" autocomplete="current-password"></label>)
                      else
                        ""
                      end
        html = <<-HTML
          <!doctype html>
          <html lang="en">
          <head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>bon print upload</title></head>
          <body>
            <main>
              <h1>bon print upload</h1>
              <form method="post" action="/print" enctype="multipart/form-data">
                <label>Documents <input type="file" name="files[]" multiple required></label>
                #{token_input}
                <button type="submit">Print</button>
              </form>
            </main>
          </body>
          </html>
          HTML
        html(context, 200, html)
      end

      private def handle_print(context : HTTP::Server::Context) : Nil
        wants_html = false
        request = context.request
        wants_html = browser_html?(request)
        return too_large(context, wants_html) if declared_too_large?(request)

        content_type = request.headers["Content-Type"]?
        unless content_type && content_type.starts_with?("multipart/form-data")
          return error(context, 415, "expected multipart/form-data", wants_html)
        end

        PrintJob.with_temp_dir("bon-web-") do |temp_dir|
          token_field = nil.as(String?)
          files = [] of String
          bytes_read = [0_i64]

          HTTP::FormData.parse(request) do |part|
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
              return error(context, 400, "unsupported upload type: #{basename}", wants_html)
            end

            path = File.join(temp_dir, "#{(files.size + 1).to_s.rjust(3, '0')}-#{basename}")
            size = write_part(part.body, path, @options.max_upload_bytes, bytes_read)
            return error(context, 400, "empty upload: #{basename}", wants_html) if size == 0
            files << path
          end

          return unauthorized(context, wants_html) unless authorized?(request, token_field)
          return error(context, 400, "no uploads provided", wants_html) if files.empty?

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
          success(context, files.size, message, wants_html)
        end
      rescue ex : UploadTooLarge
        too_large(context, browser_html?(context.request))
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

      private def browser_html?(request : HTTP::Request) : Bool
        accept = request.headers["Accept"]?
        !!(accept && accept.includes?("text/html"))
      end

      private def emit_config_warnings(loaded : LoadedConfig) : Nil
        loaded.warnings.each { |warning| @error_io.puts("warning: #{warning}") }
      end

      private def success(context : HTTP::Server::Context, files : Int32, message : String, wants_html : Bool) : Nil
        if wants_html
          html(context, 200, result_page(true, message))
        else
          json(context, 200) do |json|
            json.object do
              json.field "ok", true
              json.field "files", files
              json.field "message", message
            end
          end
        end
      end

      private def unauthorized(context : HTTP::Server::Context, wants_html : Bool) : Nil
        context.response.headers["WWW-Authenticate"] = "Bearer"
        error(context, 401, "unauthorized", wants_html)
      end

      private def too_large(context : HTTP::Server::Context, wants_html : Bool) : Nil
        error(context, 413, "upload too large", wants_html)
      end

      private def error(context : HTTP::Server::Context, status : Int32, message : String, wants_html : Bool = false) : Nil
        if wants_html
          html(context, status, result_page(false, message))
        else
          json(context, status) do |json|
            json.object do
              json.field "ok", false
              json.field "error", message
            end
          end
        end
      end

      private def result_page(ok : Bool, message : String) : String
        title = ok ? "Print Submitted" : "Print Failed"
        <<-HTML
          <!doctype html>
          <html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>#{title}</title></head>
          <body><main><h1>#{title}</h1><p>#{HTML.escape(message)}</p><p><a href="/">Back</a></p></main></body></html>
          HTML
      end

      private def text(context : HTTP::Server::Context, status : Int32, body : String) : Nil
        context.response.status_code = status
        context.response.content_type = "text/plain; charset=utf-8"
        context.response.print(body)
      end

      private def html(context : HTTP::Server::Context, status : Int32, body : String) : Nil
        context.response.status_code = status
        context.response.content_type = "text/html; charset=utf-8"
        context.response.print(body)
      end

      private def json(context : HTTP::Server::Context, status : Int32, &) : Nil
        context.response.status_code = status
        context.response.content_type = "application/json"
        JSON.build(context.response) { |builder| yield builder }
      end
    end

    class UploadTooLarge < Exception
    end
  end
end
