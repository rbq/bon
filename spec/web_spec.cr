require "file_utils"
require "http/client"
require "spec"

require "../src/bon/web"

describe Bon::Web do
  it "serves the upload form and health check" do
    with_web_server(Bon::Web::Options.new(host: "127.0.0.1", port: 0, token: "secret")) do |base_url|
      form = HTTP::Client.get("#{base_url}/")
      form.status_code.should eq(200)
      form.headers["Content-Type"].should contain("text/html")
      form.body.should contain(%(action="/print"))
      form.body.should contain(%(type="password" name="token"))

      health = HTTP::Client.get("#{base_url}/health")
      health.status_code.should eq(200)
      health.body.should eq("ok\n")
    end
  end

  it "returns 404 and 405 for unsupported routes and methods" do
    with_web_server do |base_url|
      HTTP::Client.get("#{base_url}/missing").status_code.should eq(404)
      HTTP::Client.post("#{base_url}/health", body: "").status_code.should eq(405)
    end
  end

  it "rejects unauthorized uploads when a token is configured" do
    with_web_temp_dir do |dir|
      setup_web_print_env(dir)
      with_web_env({"PATH" => "#{dir}:#{ENV["PATH"]}", "XDG_CONFIG_HOME" => File.join(dir, "xdg")}) do
        Dir.cd(dir) do
          with_web_server(Bon::Web::Options.new(host: "127.0.0.1", port: 0, token: "secret")) do |base_url|
            response = post_multipart("#{base_url}/print", [{"files[]", "receipt.pdf", "%PDF-1.7\n1 0 obj <</MediaBox [0 0 72 72]>> endobj\n"}])

            response.status_code.should eq(401)
            response.headers["WWW-Authenticate"].should eq("Bearer")
            response.body.should contain(%("ok":false))
          end
        end
      end
    end
  end

  it "accepts token auth from headers and multipart fields" do
    with_web_temp_dir do |dir|
      setup_web_print_env(dir)
      with_web_env({"PATH" => "#{dir}:#{ENV["PATH"]}", "XDG_CONFIG_HOME" => File.join(dir, "xdg")}) do
        Dir.cd(dir) do
          with_web_server(Bon::Web::Options.new(host: "127.0.0.1", port: 0, token: "secret")) do |base_url|
            header_response = post_multipart(
              "#{base_url}/print",
              [{"files[]", "receipt.pdf", "%PDF-1.7\n1 0 obj <</MediaBox [0 0 72 72]>> endobj\n"}],
              HTTP::Headers{"X-Bon-Token" => "secret"}
            )
            header_response.status_code.should eq(200)

            field_response = post_multipart(
              "#{base_url}/print",
              [{"files[]", "receipt.pdf", "%PDF-1.7\n1 0 obj <</MediaBox [0 0 72 72]>> endobj\n"}],
              fields: [{"token", "secret"}]
            )
            field_response.status_code.should eq(200)
          end
        end
      end
    end
  end

  it "rejects missing, unsupported, empty, and oversized uploads" do
    with_web_temp_dir do |dir|
      setup_web_print_env(dir)
      with_web_env({"PATH" => "#{dir}:#{ENV["PATH"]}", "XDG_CONFIG_HOME" => File.join(dir, "xdg")}) do
        Dir.cd(dir) do
          with_web_server do |base_url|
            post_multipart("#{base_url}/print", [] of Tuple(String, String, String), fields: [{"note", "none"}]).status_code.should eq(400)
            post_multipart("#{base_url}/print", [{"files[]", "receipt.gif", "GIF89a"}]).status_code.should eq(400)
            post_multipart("#{base_url}/print", [{"files[]", "empty.pdf", ""}]).status_code.should eq(400)
          end

          with_web_server(Bon::Web::Options.new(host: "127.0.0.1", port: 0, max_upload_bytes: 40)) do |base_url|
            post_multipart("#{base_url}/print", [{"files[]", "receipt.pdf", "%PDF-1.7\n1 0 obj <</MediaBox [0 0 72 72]>> endobj\n"}]).status_code.should eq(413)
          end
        end
      end
    end
  end

  it "prints single and multiple uploads through the shared dry-run pipeline in upload order" do
    with_web_temp_dir do |dir|
      setup_web_print_env(dir)
      stdout = IO::Memory.new
      stderr = IO::Memory.new

      with_web_env({"PATH" => "#{dir}:#{ENV["PATH"]}", "XDG_CONFIG_HOME" => File.join(dir, "xdg")}) do
        Dir.cd(dir) do
          with_web_server(Bon::Web::Options.new(host: "127.0.0.1", port: 0), stdout, stderr) do |base_url|
            response = post_multipart("#{base_url}/print", [
              {"files[]", "a.pdf", "%PDF-1.7\n1 0 obj <</MediaBox [0 0 72 72]>> endobj\n"},
              {"files[]", "b.pdf", "%PDF-1.7\n1 0 obj <</MediaBox [0 0 80 72]>> endobj\n"},
            ])

            response.status_code.should eq(200)
            response.body.should contain(%("ok":true))
            response.body.should contain(%("files":2))
            output = stdout.to_s
            output.should contain("lp -d EPSON_TM_m30III -n 1")
            output.index("001-a.pdf").not_nil!.should be < output.index("002-b.pdf").not_nil!
            stderr.to_s.should eq("")
          end
        end
      end
    end
  end

  it "returns HTML result pages for browser form posts" do
    with_web_temp_dir do |dir|
      setup_web_print_env(dir)
      with_web_env({"PATH" => "#{dir}:#{ENV["PATH"]}", "XDG_CONFIG_HOME" => File.join(dir, "xdg")}) do
        Dir.cd(dir) do
          with_web_server do |base_url|
            response = post_multipart(
              "#{base_url}/print",
              [{"file", "receipt.pdf", "%PDF-1.7\n1 0 obj <</MediaBox [0 0 72 72]>> endobj\n"}],
              HTTP::Headers{"Accept" => "text/html"}
            )

            response.status_code.should eq(200)
            response.headers["Content-Type"].should contain("text/html")
            response.body.should contain("submitted 1 file(s)")
          end
        end
      end
    end
  end
end

private def with_web_server(options = Bon::Web::Options.new(host: "127.0.0.1", port: 0), output_io : IO = IO::Memory.new, error_io : IO = IO::Memory.new, & : String ->) : Nil
  app = Bon::Web::Application.new(options, output_io, error_io)
  server = HTTP::Server.new do |context|
    app.call(context)
  end
  address = server.bind_tcp(options.host, options.port)
  fiber = spawn { server.listen }
  begin
    yield "http://#{address.address}:#{address.port}"
  ensure
    server.close
  end
end

private def post_multipart(url : String, files : Array(Tuple(String, String, String)), headers = HTTP::Headers.new, fields = [] of Tuple(String, String)) : HTTP::Client::Response
  boundary = "bon-spec-#{Random.rand(1_000_000)}"
  body = IO::Memory.new
  fields.each do |name, value|
    body << "--#{boundary}\r\n"
    body << %(Content-Disposition: form-data; name="#{name}"\r\n\r\n)
    body << value
    body << "\r\n"
  end
  files.each do |field, filename, content|
    body << "--#{boundary}\r\n"
    body << %(Content-Disposition: form-data; name="#{field}"; filename="#{filename}"\r\n)
    body << "Content-Type: application/octet-stream\r\n\r\n"
    body << content
    body << "\r\n"
  end
  body << "--#{boundary}--\r\n"
  headers = headers.dup
  headers["Content-Type"] = "multipart/form-data; boundary=#{boundary}"
  headers["Accept"] ||= "application/json"
  HTTP::Client.post(url, headers, body.to_s)
end

private def setup_web_print_env(dir : String) : Nil
  File.write(File.join(dir, "bon.toml"), "[cups]\ndry_run = true\n")
  install_web_fake_lpstat(dir)
  install_web_fake_print_tools(dir)
end

private def install_web_fake_print_tools(dir : String) : Nil
  File.write(File.join(dir, "lp"), <<-SH)
    #!/bin/sh
    exit 0
    SH
  File.chmod(File.join(dir, "lp"), 0o755)

  File.write(File.join(dir, "lpoptions"), <<-SH)
    #!/bin/sh
    printf '%s\n' 'PageSize/Media Size: *RP80x200 RP80x2000 Custom.WIDTHxHEIGHT'
    printf '%s\n' 'Resolution/Resolution: *203x203dpi'
    printf '%s\n' 'TmxPaperReduction/Paper Reduction: *Off Top Bottom Both'
    printf '%s\n' 'TmxPaperCut/Paper Cut: NoCut CutPerJob *CutPerPage'
    SH
  File.chmod(File.join(dir, "lpoptions"), 0o755)
end

private def install_web_fake_lpstat(dir : String) : Nil
  path = File.join(dir, "lpstat")
  File.write(path, <<-SH)
    #!/bin/sh
    case "$1" in
      -v)
        printf '%s\n' 'device for EPSON_TM_m30III: dnssd://EPSON%20TM-m30III._ipps._tcp.local/'
        ;;
      -p)
        printf '%s\n' 'printer EPSON_TM_m30III is idle. enabled since today'
        ;;
      *)
        exit 2
        ;;
    esac
    SH
  File.chmod(path, 0o755)
end

private def with_web_temp_dir(& : String ->) : Nil
  dir = File.join(Dir.tempdir, "bon-web-spec-#{Process.pid}-#{Time.utc.to_unix_ns}-#{Random.rand(1_000_000)}")
  Dir.mkdir(dir)
  begin
    yield dir
  ensure
    FileUtils.rm_rf(dir)
  end
end

private def with_web_env(values : Hash(String, String), & : ->) : Nil
  previous = values.keys.to_h { |key| {key, ENV[key]?} }
  values.each { |key, value| ENV[key] = value }
  begin
    yield
  ensure
    previous.each do |key, value|
      if value
        ENV[key] = value
      else
        ENV.delete(key)
      end
    end
  end
end
