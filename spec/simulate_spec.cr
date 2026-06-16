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

  it "builds output paths by stripping the actual input extension" do
    with_temp_dir do |dir|
      source = File.join(dir, "receipt.png")
      Bon::Simulate.write_png(source, 1, 1, Bytes[255, 255, 255])

      output = Bon::Simulate.output_path(source, Bon::Simulate::Options.new)

      output.should eq(File.join(dir, "receipt_80mm-printout.png"))
    end
  end

  it "discovers Typst and supported image inputs by default" do
    with_temp_dir do |dir|
      typ = File.join(dir, "a.typ")
      png = File.join(dir, "b.png")
      jpg = File.join(dir, "c.jpg")
      jpeg = File.join(dir, "d.jpeg")
      File.write(typ, "#set page(width: 80mm, height: auto)\n")
      Bon::Simulate.write_png(png, 1, 1, Bytes[255, 255, 255])
      File.write(jpg, "stub")
      File.write(jpeg, "stub")

      Bon::Simulate.default_sources(dir).should eq([typ, png, jpg, jpeg].sort)
    end
  end

  it "simulates PNG inputs directly without Typst" do
    with_temp_dir do |dir|
      source = File.join(dir, "receipt.png")
      Bon::Simulate.write_png(source, 4, 2, Bytes[
        0, 0, 0, 255, 255, 255, 255, 255, 255, 0, 0, 0,
        0, 0, 0, 255, 255, 255, 255, 255, 255, 0, 0, 0,
      ])
      options = Bon::Simulate::Options.new(paper_mm: 80.0, content_mm: 40.0, top_mm: 0.0, bottom_mm: 0.0, out_dir: dir)

      outputs = Bon::Simulate.render_sources([source], options)

      outputs.should eq([File.join(dir, "receipt_80mm-printout.png")])
      File.exists?(outputs.first).should be_true
    end
  end

  it "uses printable width to center-crop wider PNG inputs by default" do
    with_temp_dir do |dir|
      source = File.join(dir, "wide.png")
      rgb = Bytes.new(600 * 4 * 3, 255_u8)
      4.times do |y|
        600.times do |x|
          next unless x < 12 || x >= 588
          offset = (y * 600 + x) * 3
          rgb[offset] = 0_u8
          rgb[offset + 1] = 0_u8
          rgb[offset + 2] = 0_u8
        end
      end
      Bon::Simulate.write_png(source, 600, 4, rgb)
      options = Bon::Simulate::Options.new(
        paper_mm: 80.0,
        printable_width_mm: Bon::Config.default_printable_width_pt(80.0) * 25.4 / 72.0,
        ppi: 203,
        mockup_ppi: 203,
        top_mm: 0.0,
        bottom_mm: 0.0,
        out_dir: dir
      )

      outputs = Bon::Simulate.render_sources([source], options)
      mockup = Bon::Simulate.read_png(outputs.first)

      mockup.width.should eq((80.0 / 25.4 * 203).round.to_i)
      mockup.height.should eq(6)
      dark_pixel_count(mockup).should eq(0)
    end
  end
end

describe Bon::Cli do
  it "runs simulate through the sim alias" do
    with_temp_dir do |dir|
      source = File.join(dir, "receipt.png")
      xdg_config = File.join(dir, "xdg")
      Bon::Simulate.write_png(source, 2, 1, Bytes[0, 0, 0, 255, 255, 255])

      with_env({"XDG_CONFIG_HOME" => xdg_config}) do
        Dir.cd(dir) do
          expected_output = File.join(Dir.current, "receipt_80mm-printout.png")
          stdout = IO::Memory.new
          stderr = IO::Memory.new

          status = Bon::Cli.run(["sim", File.basename(source)], stdout, stderr)

          status.should eq(0)
          stderr.to_s.should eq("")
          stdout.to_s.strip.should eq(expected_output)
          File.exists?(expected_output).should be_true
        end
      end
    end
  end

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

private def dark_pixel_count(raster : Bon::Simulate::Raster) : Int32
  count = 0
  (raster.width * raster.height).times do |index|
    offset = index * raster.channels
    count += 1 if raster.pixels[offset].to_i < 150 && raster.pixels[offset + 1].to_i < 150 && raster.pixels[offset + 2].to_i < 150
  end
  count
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
