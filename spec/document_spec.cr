require "compress/zlib"
require "digest/crc32"
require "file_utils"
require "spec"
require "../src/bon/document"

describe Bon::Document do
  it "prepares Typst sources by rendering directly to a printer-resolution PNG" do
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
        config = Bon::Config.new(image_ppi: 1, raster_ppi_multiplier: 2, typst_bin: fake_typst)

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
