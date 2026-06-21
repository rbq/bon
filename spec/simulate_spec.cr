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

  it "applies minimum printer margins even when configured margins are zero" do
    with_temp_dir do |dir|
      source = File.join(dir, "receipt.png")
      Bon::Simulate.write_png(source, 1, 1, Bytes[255, 255, 255])
      options = Bon::Simulate::Options.new(
        paper_mm: 1.0,
        content_mm: 1.0,
        mockup_ppi: 25,
        top_mm: 0.0,
        bottom_mm: 0.0,
        min_top_mm: 12.0,
        min_bottom_mm: 2.0,
        out_dir: dir
      )

      outputs = Bon::Simulate.render_sources([source], options)
      mockup = Bon::Simulate.read_png(outputs.first)

      mockup.height.should eq(15)
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
        min_top_mm: 0.0,
        min_bottom_mm: 0.0,
        out_dir: dir
      )

      outputs = Bon::Simulate.render_sources([source], options)
      mockup = Bon::Simulate.read_png(outputs.first)

      mockup.width.should eq((80.0 / 25.4 * 203).round.to_i)
      mockup.height.should eq(4)
      dark_pixel_count(mockup).should eq(0)
    end
  end

  it "renders one mockup per Typst page" do
    with_temp_dir do |dir|
      source = File.join(dir, "multi.typ")
      fake_png = File.join(dir, "content.png")
      fake_typst = File.join(dir, "typst")
      File.write(source, "#set page(width: 80mm, height: 80mm)\nfirst\n#pagebreak()\nsecond\n")
      Bon::Simulate.write_png(fake_png, 2, 1, Bytes[0, 0, 0, 255, 255, 255])
      File.write(fake_typst, <<-SH)
        #!/bin/sh
        output=""
        for arg do
          output="$arg"
        done
        case "$output" in
          *"{p}"*)
            prefix=${output%%"{p}"*}
            suffix=${output#*"{p}"}
            cp "$BON_FAKE_PNG" "${prefix}1${suffix}"
            cp "$BON_FAKE_PNG" "${prefix}2${suffix}"
            ;;
          *)
            cp "$BON_FAKE_PNG" "$output"
            ;;
        esac
        SH
      File.chmod(fake_typst, 0o755)

      with_env({"BON_FAKE_PNG" => fake_png}) do
        options = Bon::Simulate::Options.new(typst_bin: fake_typst, out_dir: dir, top_mm: 0.0, bottom_mm: 0.0)

        outputs = Bon::Simulate.render_sources([source], options)

        outputs.should eq([
          File.join(dir, "multi-page-001_80mm-printout.png"),
          File.join(dir, "multi-page-002_80mm-printout.png"),
        ])
        outputs.each { |output| File.exists?(output).should be_true }
      end
    end
  end

  it "parses foreground colors from hex RGB values" do
    Bon::Simulate.parse_color("#112233").should eq({17, 34, 51})
    Bon::Simulate.parse_color("112233").should eq({17, 34, 51})
  end

  it "applies foreground color and fade without changing the default path" do
    with_temp_dir do |dir|
      source = File.join(dir, "source.png")
      white_output = File.join(dir, "white.png")
      faded_output = File.join(dir, "faded.png")
      red_output = File.join(dir, "red.png")

      Bon::Simulate.write_png(source, 1, 1, Bytes[0, 0, 0])
      Bon::Simulate.simulate_png(source, faded_output, 1.0, 1.0, 25, 0.0, 0.0, 42, nil, Bon::Simulate::PAPER_RGB, Bon::Simulate::INK_RGB, 0.0)
      Bon::Simulate.write_png(source, 1, 1, Bytes[255, 255, 255])
      Bon::Simulate.simulate_png(source, white_output, 1.0, 1.0, 25, 0.0, 0.0, 42)

      pixel_at(faded_output, 0).should eq(pixel_at(white_output, 0))

      Bon::Simulate.write_png(source, 1, 1, Bytes[0, 0, 0])
      Bon::Simulate.simulate_png(source, red_output, 1.0, 1.0, 25, 0.0, 0.0, 42, nil, Bon::Simulate::PAPER_RGB, {255, 0, 0}, 1.0)

      red, green, blue = pixel_at(red_output, 0)
      red.should be > green
      red.should be > blue
    end
  end

  it "renders JPEG wrappers with the temporary directory as the Typst root" do
    with_temp_dir do |dir|
      source_dir = File.join(dir, "source")
      temp_dir = File.join(dir, "simulate-root")
      FileUtils.mkdir_p(source_dir)
      FileUtils.mkdir_p(temp_dir)
      source = File.join(source_dir, "receipt.jpg")
      fake_png = File.join(dir, "content.png")
      fake_typst = File.join(dir, "typst")
      log = File.join(dir, "typst-args.log")

      write_jpeg_dimensions(source, 1, 1)
      Bon::Simulate.write_png(fake_png, 1, 1, Bytes[255, 255, 255])
      File.write(fake_typst, <<-SH)
        #!/bin/sh
        printf '%s\n' "$@" > "$BON_TYPST_LOG"
        output=""
        for arg do
          output="$arg"
        done
        cp "$BON_FAKE_PNG" "$output"
        SH
      File.chmod(fake_typst, 0o755)

      with_env({"BON_FAKE_PNG" => fake_png, "BON_TYPST_LOG" => log}) do
        options = Bon::Simulate::Options.new(typst_bin: fake_typst, out_dir: dir, top_mm: 0.0, bottom_mm: 0.0)

        Bon::Simulate.render_source(source, temp_dir, options)

        args = File.read(log).lines.map(&.chomp)
        root_index = args.index("--root").not_nil!
        args[root_index + 1].should eq(temp_dir)
        args.should_not contain(source_dir)
        File.read(File.join(temp_dir, "receipt-image-wrapper.typ")).should contain("#image(\"source.jpg\"")
        File.exists?(File.join(temp_dir, "source.jpg")).should be_true
      end
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

  it "uses configured simulate foreground options" do
    with_temp_dir do |dir|
      source = File.join(dir, "receipt.typ")
      fake_png = File.join(dir, "content.png")
      fake_typst = File.join(dir, "typst")
      xdg_config = File.join(dir, "xdg")

      File.write(source, "#set page(width: 1mm, height: auto)\nHello\n")
      Bon::Simulate.write_png(fake_png, 1, 1, Bytes[0, 0, 0])
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
          File.write("config.toml", <<-TOML)
            [paper]
            width_mm = 2.0
            printable_width_pt = 5.0

            [render]
            image_ppi = 25

            [simulate]
            foreground_color = "#ff0000"
            foreground_fade = 1.0
            min_top_mm = 0.0
            min_bottom_mm = 0.0
          TOML

          stdout = IO::Memory.new
          stderr = IO::Memory.new

          status = Bon::Cli.run(["simulate", "--typst-bin=#{fake_typst}", "--top-mm=0", "--bottom-mm=0", File.basename(source)], stdout, stderr)

          status.should eq(0)
          stderr.to_s.should eq("")
          red, green, blue = pixel_at(stdout.to_s.strip, 0)
          red.should be > green
          red.should be > blue
        end
      end
    end
  end

  it "uses configured simulate vertical margins" do
    with_temp_dir do |dir|
      source = File.join(dir, "receipt.png")
      xdg_config = File.join(dir, "xdg")
      Bon::Simulate.write_png(source, 1, 1, Bytes[255, 255, 255])

      with_env({"XDG_CONFIG_HOME" => xdg_config}) do
        Dir.cd(dir) do
          File.write("config.toml", <<-TOML)
            [paper]
            width_mm = 1.0
            printable_width_pt = 1.0

            [render]
            image_ppi = 25

            [simulate]
            top_mm = 4.0
            bottom_mm = 8.0
            min_top_mm = 0.0
            min_bottom_mm = 0.0
          TOML

          stdout = IO::Memory.new
          stderr = IO::Memory.new

          status = Bon::Cli.run(["simulate", "--mockup-ppi=25", File.basename(source)], stdout, stderr)

          status.should eq(0)
          stderr.to_s.should eq("")
          mockup = Bon::Simulate.read_png(stdout.to_s.strip)
          mockup.height.should eq(13)
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

private def pixel_at(path : String, index : Int32) : Tuple(UInt8, UInt8, UInt8)
  raster = Bon::Simulate.read_png(path)
  offset = index * raster.channels
  {raster.pixels[offset], raster.pixels[offset + 1], raster.pixels[offset + 2]}
end

private def write_jpeg_dimensions(path : String, width : Int32, height : Int32) : Nil
  File.open(path, "w") do |file|
    file.write(Bytes[0xff, 0xd8, 0xff, 0xc0])
    file.write_bytes(8_u16, IO::ByteFormat::BigEndian)
    file.write_byte(8_u8)
    file.write_bytes(height.to_u16, IO::ByteFormat::BigEndian)
    file.write_bytes(width.to_u16, IO::ByteFormat::BigEndian)
    file.write_byte(1_u8)
    file.write(Bytes[0xff, 0xd9])
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
