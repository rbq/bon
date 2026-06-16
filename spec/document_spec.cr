require "compress/zlib"
require "digest/crc32"
require "file_utils"
require "spec"
require "../src/bon/document"

describe Bon::Document do
  it "prepares Typst sources as PDFs by default" do
    with_document_temp_dir do |dir|
      source = File.join(dir, "receipt.typ")
      fake_typst = File.join(dir, "typst")
      args = File.join(dir, "typst-args.txt")
      output = IO::Memory.new
      error = IO::Memory.new

      File.write(source, "#set page(width: 80mm, height: auto)\nHello\n")
      File.write(fake_typst, <<-SH)
        #!/bin/sh
        printf '%s\n' "$@" > "$BON_TYPST_ARGS"
        output=""
        for arg do
          output="$arg"
        done
        cat > "$output" <<'PDF'
        %PDF-1.7
        1 0 obj <</MediaBox [0 0 180 300]>> endobj
        PDF
        SH
      File.chmod(fake_typst, 0o755)

      with_document_env({"BON_TYPST_ARGS" => args}) do
        config = Bon::Config.new(typst_bin: fake_typst)

        prepared = Bon::Document.prepare(source, dir, 1, config, false, false, output, error)

        prepared.path.should eq(File.join(dir, "001-receipt.pdf"))
        prepared.size.width.should eq(180.0)
        prepared.size.height.should eq(300.0)
        typst_args = File.read(args)
        typst_args.should contain("compile")
        typst_args.should contain("--root")
        typst_args.should_not contain("--ppi")
        typst_args.should_not contain("-f")
        typst_args.should_not contain("png")
      end
    end
  end

  it "center-crops wide Typst PDFs with Ghostscript pdfwrite" do
    with_document_temp_dir do |dir|
      source = File.join(dir, "receipt.typ")
      fake_typst = File.join(dir, "typst")
      fake_gs = File.join(dir, "gs")
      gs_args = File.join(dir, "gs-args.txt")
      output = IO::Memory.new
      error = IO::Memory.new

      File.write(source, "#set page(width: 80mm, height: 300pt)\nHello\n")
      File.write(fake_typst, <<-SH)
        #!/bin/sh
        output=""
        for arg do
          output="$arg"
        done
        cat > "$output" <<'PDF'
        %PDF-1.7
        1 0 obj <</MediaBox [0 0 226.772 300]>> endobj
        PDF
        SH
      File.chmod(fake_typst, 0o755)
      File.write(fake_gs, <<-SH)
        #!/bin/sh
        printf '%s\n' "$@" > "$BON_GS_ARGS"
        output=""
        for arg do
          case "$arg" in
            -sOutputFile=*) output="${arg#-sOutputFile=}" ;;
          esac
        done
        cat > "$output" <<'PDF'
        %PDF-1.7
        1 0 obj <</MediaBox [0 0 204.3 300]>> endobj
        PDF
        SH
      File.chmod(fake_gs, 0o755)

      with_document_env({"PATH" => "#{dir}:#{ENV["PATH"]?}", "BON_GS_ARGS" => gs_args}) do
        config = Bon::Config.new(typst_bin: fake_typst)

        prepared = Bon::Document.prepare(source, dir, 1, config, false, true, output, error)

        prepared.path.should eq(File.join(dir, "001-receipt-print.pdf"))
        prepared.size.width.should eq(204.3)
        prepared.size.height.should eq(300.0)
        output.to_s.should contain("compile --root")
        output.to_s.should_not contain("--ppi")
        output.to_s.should contain("-sDEVICE=pdfwrite")
        output.to_s.should contain("-dDEVICEWIDTHPOINTS=204.3")
        File.read(gs_args).should contain("<</PageOffset [-11.236 0]>> setpagedevice")
      end
    end
  end

  it "prepares LaTeX sources as PDFs by default" do
    with_document_temp_dir do |dir|
      source = File.join(dir, "receipt.tex")
      fake_pdflatex = File.join(dir, "pdflatex")
      args = File.join(dir, "pdflatex-args.txt")
      output = IO::Memory.new
      error = IO::Memory.new

      File.write(source, "\\documentclass{article}\\begin{document}Hello\\end{document}\n")
      File.write(fake_pdflatex, fake_pdflatex_script(args, 180.0, 300.0))
      File.chmod(fake_pdflatex, 0o755)

      with_document_env({"PATH" => "#{dir}:#{ENV["PATH"]?}"}) do
        config = Bon::Config.new(latex_engine: "pdflatex")

        prepared = Bon::Document.prepare(source, dir, 1, config, false, false, output, error)

        prepared.path.should eq(File.join(dir, "001-receipt.pdf"))
        prepared.size.width.should eq(180.0)
        prepared.size.height.should eq(300.0)
        pdflatex_args = File.read(args)
        pdflatex_args.should contain("-output-directory")
        output.to_s.should_not contain("pngmono")
        output.to_s.should_not contain("pnggray")
        output.to_s.should_not contain("001-receipt-print.png")
      end
    end
  end

  it "center-crops wide LaTeX PDFs with Ghostscript pdfwrite" do
    with_document_temp_dir do |dir|
      source = File.join(dir, "receipt.tex")
      fake_pdflatex = File.join(dir, "pdflatex")
      fake_gs = File.join(dir, "gs")
      pdflatex_args = File.join(dir, "pdflatex-args.txt")
      gs_args = File.join(dir, "gs-args.txt")
      output = IO::Memory.new
      error = IO::Memory.new

      File.write(source, "\\documentclass{article}\\begin{document}Hello\\end{document}\n")
      File.write(fake_pdflatex, fake_pdflatex_script(pdflatex_args, 226.772, 300.0))
      File.chmod(fake_pdflatex, 0o755)
      File.write(fake_gs, <<-SH)
        #!/bin/sh
        printf '%s\n' "$@" > "$BON_GS_ARGS"
        output=""
        for arg do
          case "$arg" in
            -sOutputFile=*) output="${arg#-sOutputFile=}" ;;
          esac
        done
        cat > "$output" <<'PDF'
        %PDF-1.7
        1 0 obj <</MediaBox [0 0 204.3 300]>> endobj
        PDF
        SH
      File.chmod(fake_gs, 0o755)

      with_document_env({"PATH" => "#{dir}:#{ENV["PATH"]?}", "BON_GS_ARGS" => gs_args}) do
        config = Bon::Config.new(latex_engine: "pdflatex")

        prepared = Bon::Document.prepare(source, dir, 1, config, false, true, output, error)

        prepared.path.should eq(File.join(dir, "001-receipt-print.pdf"))
        prepared.size.width.should eq(204.3)
        prepared.size.height.should eq(300.0)
        output.to_s.should contain("pdflatex -interaction=nonstopmode")
        output.to_s.should contain("-sDEVICE=pdfwrite")
        output.to_s.should contain("-dDEVICEWIDTHPOINTS=204.3")
        output.to_s.should_not contain("pngmono")
        output.to_s.should_not contain("pnggray")
        output.to_s.should_not contain("001-receipt-print.png")
        File.read(gs_args).should contain("<</PageOffset [-11.236 0]>> setpagedevice")
      end
    end
  end

  it "uses the legacy Typst raster pipeline only when configured" do
    with_document_temp_dir do |dir|
      source = File.join(dir, "receipt.typ")
      fake_typst = File.join(dir, "typst")
      fake_png = File.join(dir, "typst-output.png")
      output = IO::Memory.new
      error = IO::Memory.new

      File.write(source, "#set page(width: 80mm, height: auto)\nHello\n")
      write_rgb_png(fake_png, 4, 2, Bytes[0, 0, 0, 255, 255, 255, 0, 0, 0, 255, 255, 255, 255, 255, 255, 0, 0, 0, 255, 255, 255, 0, 0, 0])
      File.write(fake_typst, <<-SH)
        #!/bin/sh
        output=""
        for arg do
          output="$arg"
        done
        cp "$BON_FAKE_PNG" "$output"
        SH
      File.chmod(fake_typst, 0o755)

      with_document_env({"BON_FAKE_PNG" => fake_png}) do
        config = Bon::Config.new(typst_mode: "raster", image_ppi: 1, raster_ppi_multiplier: 2, typst_bin: fake_typst)

        prepared = Bon::Document.prepare(source, dir, 1, config, false, false, output, error)

        prepared.path.should eq(File.join(dir, "001-receipt-print.png"))
        Bon::Image.dimensions(prepared.path).should eq(Bon::Image::Dimensions.new(2, 1))
        prepared.size.width.should eq(144.0)
        prepared.size.height.should eq(72.0)
      end
    end
  end

  it "prepares fitting images for direct CUPS submission" do
    config = Bon::Config.new(image_ppi: 200)
    File.tempfile("bon-document", ".png") do |image|
      write_png_header(image, 100, 50)

      prepared = Bon::Document.prepare(image.path, Dir.tempdir, 1, config, false, true)

      prepared.path.should eq(File.expand_path(image.path))
      prepared.size.width.should eq(36.0)
      prepared.size.height.should eq(18.0)
    end
  end

  it "rejects images wider than the configured paper" do
    config = Bon::Config.new(image_ppi: 72, paper_width_mm: 10.0)
    File.tempfile("bon-document", ".png") do |image|
      write_png_header(image, 100, 50)

      expect_raises(Bon::Error, /exceeds .* paper width/) do
        Bon::Document.prepare(image.path, Dir.tempdir, 1, config, false, true)
      end
    end
  end
end

private def fake_pdflatex_script(args_path : String, width : Float64, height : Float64) : String
  <<-SH
    #!/bin/sh
    printf '%s\n' "$@" > #{args_path}
    outdir="."
    source=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -output-directory)
          shift
          outdir="$1"
          ;;
        *)
          source="$1"
          ;;
      esac
      shift
    done
    basename="${source##*/}"
    basename="${basename%.*}"
    cat > "$outdir/$basename.pdf" <<'PDF'
    %PDF-1.7
    1 0 obj <</MediaBox [0 0 #{width} #{height}]>> endobj
    PDF
    SH
end

private def with_document_temp_dir(& : String ->) : Nil
  dir = File.join(Dir.tempdir, "bon-document-spec-#{Process.pid}-#{Time.utc.to_unix_ns}-#{Random.rand(1_000_000)}")
  Dir.mkdir(dir)
  begin
    yield dir
  ensure
    FileUtils.rm_rf(dir)
  end
end

private def with_document_env(values : Hash(String, String), & : ->) : Nil
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

private def write_png_header(file : File, width : Int32, height : Int32) : Nil
  file.write(Bytes[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
  file.write(Bytes[0x00, 0x00, 0x00, 0x0d])
  file.write("IHDR".to_slice)
  file.write_byte((width >> 24).to_u8)
  file.write_byte((width >> 16).to_u8)
  file.write_byte((width >> 8).to_u8)
  file.write_byte(width.to_u8)
  file.write_byte((height >> 24).to_u8)
  file.write_byte((height >> 16).to_u8)
  file.write_byte((height >> 8).to_u8)
  file.write_byte(height.to_u8)
  file.write(Bytes[0x08, 0x02, 0x00, 0x00, 0x00])
  file.write(Bytes[0x00, 0x00, 0x00, 0x00])
  file.flush
end

private def write_rgb_png(path : String, width : Int32, height : Int32, pixels : Bytes) : Nil
  rows = IO::Memory.new
  stride = width * 3
  height.times do |row|
    rows.write_byte(0_u8)
    rows.write(pixels[row * stride, stride])
  end

  ihdr = IO::Memory.new
  write_document_u32(ihdr, width)
  write_document_u32(ihdr, height)
  ihdr.write(Bytes[8, 2, 0, 0, 0])

  png = IO::Memory.new
  png.write(Bytes[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
  write_document_chunk(png, "IHDR", ihdr.to_slice)
  write_document_chunk(png, "IDAT", deflate_document(rows.to_slice))
  write_document_chunk(png, "IEND", Bytes.empty)
  File.write(path, png.to_slice)
end

private def deflate_document(data : Bytes) : Bytes
  io = IO::Memory.new
  Compress::Zlib::Writer.open(io) { |zlib| zlib.write(data) }
  io.to_slice
end

private def write_document_u32(io : IO, value) : Nil
  number = value.to_u32
  io.write_byte(((number >> 24) & 0xff).to_u8)
  io.write_byte(((number >> 16) & 0xff).to_u8)
  io.write_byte(((number >> 8) & 0xff).to_u8)
  io.write_byte((number & 0xff).to_u8)
end

private def write_document_chunk(output : IO, name : String, payload : Bytes) : Nil
  write_document_u32(output, payload.size)
  name_bytes = name.to_slice
  output.write(name_bytes)
  output.write(payload)
  crc_input = IO::Memory.new
  crc_input.write(name_bytes)
  crc_input.write(payload)
  write_document_u32(output, Digest::CRC32.checksum(crc_input.to_slice))
end
