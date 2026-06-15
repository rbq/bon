require "file_utils"
require "spec"

require "../src/bon/cli"

describe Bon::Simulate do
  it "builds default output paths next to the source file" do
    with_temp_dir do |dir|
      source = File.join(dir, "receipt.typ")
      File.write(source, "#set page(width: 80mm, height: auto)\n")

      output = Bon::Simulate.output_path(source, Bon::Simulate::Options.new)

      output.should eq(File.join(dir, "receipt_80mm-printout.png"))
    end
  end
end

describe Bon::Cli do
  it "writes simulate PNGs next to the source and prints the full generated path" do
    with_temp_dir do |dir|
      source = File.join(dir, "receipt.typ")
      fake_png = File.join(dir, "content.png")
      fake_typst = File.join(dir, "typst")
      xdg_config = File.join(dir, "xdg")

      File.write(source, "#set page(width: 80mm, height: auto)\nHello\n")
      Bon::Simulate.write_png(fake_png, 2, 1, Bytes[0, 0, 0, 255, 255, 255])
      File.write(fake_typst, <<-SH)
        #!/bin/sh
        output=""
        for arg do
          output="$arg"
        done
        cp "$BON_FAKE_PNG" "$output"
        SH
      File.chmod(fake_typst, 0o755)

      with_env({"BON_FAKE_PNG" => fake_png, "XDG_CONFIG_HOME" => xdg_config}) do
        Dir.cd(dir) do
          expected_output = File.join(Dir.current, "receipt_80mm-printout.png")
          stdout = IO::Memory.new
          stderr = IO::Memory.new

          status = Bon::Cli.run(["simulate", "--typst-bin=#{fake_typst}", File.basename(source)], stdout, stderr)

          status.should eq(0)
          stderr.to_s.should eq("")
          stdout.to_s.strip.should eq(expected_output)
          File.exists?(expected_output).should be_true
        end
      end
    end
  end
end

private def with_temp_dir(& : String ->) : Nil
  dir = File.join(Dir.tempdir, "bon-spec-#{Process.pid}-#{Time.utc.to_unix_ns}-#{Random.rand(1_000_000)}")
  Dir.mkdir(dir)
  begin
    yield dir
  ensure
    FileUtils.rm_rf(dir)
  end
end

private def with_env(values : Hash(String, String), & : ->) : Nil
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
