require "spec"
require "../src/bon/pdf"

describe Bon::PDF do
  it "reads the first PDF crop or media box" do
    File.tempfile("bon-pdf", ".pdf") do |file|
      file.print("%PDF-1.7\n1 0 obj <</MediaBox [0 0 226.77 500]>> endobj\n")
      file.flush

      size = Bon::PDF.first_page_size(file.path)
      size.width.should eq(226.77)
      size.height.should eq(500.0)
    end
  end

  it "formats point values without unnecessary decimals" do
    Bon::PDF.format_points(204.30).should eq("204.3")
    Bon::PDF.format_points(72.0).should eq("72")
    Bon::PDF.format_points(204.2955665).should eq("204.296")
  end

  it "converts printer points to exact dot dimensions" do
    width_px = Bon::PDF.points_to_pixels(204.3, 203)
    width_px.should eq(576)
    Bon::PDF.format_points(Bon::PDF.pixels_to_points(width_px, 203)).should eq("204.296")
  end

  it "builds a single raster crop command at printer resolution" do
    source_size = Bon::PDF::PageSize.new(226.772, 288.0)
    target_size = Bon::PDF::PageSize.new(
      Bon::PDF.pixels_to_points(576, 203),
      Bon::PDF.pixels_to_points(812, 203)
    )

    command = Bon::PDF.raster_crop_command("gs", "source.pdf", "print.png", source_size, target_size, 203)

    command.should contain("-sDEVICE=pngmono")
    command.should contain("-r203x203")
    command.should contain("-dTextAlphaBits=1")
    command.should contain("-dGraphicsAlphaBits=1")
    command.should contain("-dDEVICEWIDTHPOINTS=204.296")
    command.should contain("-dDEVICEHEIGHTPOINTS=288")
    command.should contain("-sOutputFile=print.png")
    command.should contain("<</PageOffset [-11.238 0]>> setpagedevice")
  end

  it "can build a higher-resolution grayscale raster command" do
    source_size = Bon::PDF::PageSize.new(226.772, 288.0)
    target_size = Bon::PDF::PageSize.new(
      Bon::PDF.pixels_to_points(576, 203),
      Bon::PDF.pixels_to_points(812, 203)
    )

    command = Bon::PDF.raster_crop_command("gs", "source.pdf", "print-406ppi.png", source_size, target_size, 406, grayscale: true)

    command.should contain("-sDEVICE=pnggray")
    command.should contain("-r406x406")
    command.should contain("-dTextAlphaBits=4")
    command.should contain("-dGraphicsAlphaBits=4")
  end

  it "downsamples a high-resolution grayscale raster to native 1-bit PNG dimensions" do
    File.tempfile("bon-high", ".png") do |high|
      File.tempfile("bon-native", ".png") do |native|
        write_gray_png(high.path, 4, 2, Bytes[0, 0, 0, 0, 255, 255, 255, 255])

        Bon::PDF.downsample_grayscale_to_mono(high.path, native.path, 2)

        File.open(native.path) do |file|
          signature = Bytes.new(8)
          file.read_fully(signature)
          signature.should eq(Bytes[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
          file.read_bytes(UInt32, IO::ByteFormat::BigEndian).should eq(13)
          type = Bytes.new(4)
          file.read_fully(type)
          String.new(type).should eq("IHDR")
          file.read_bytes(UInt32, IO::ByteFormat::BigEndian).should eq(2)
          file.read_bytes(UInt32, IO::ByteFormat::BigEndian).should eq(1)
          file.read_byte.should eq(1)
          file.read_byte.should eq(0)
        end
      end
    end
  end
end

private def write_gray_png(path : String, width : Int32, height : Int32, pixels : Bytes) : Nil
  rows = IO::Memory.new
  height.times do |row|
    rows.write_byte(0_u8)
    rows.write(pixels[row * width, width])
  end

  ihdr = IO::Memory.new
  write_spec_u32(ihdr, width)
  write_spec_u32(ihdr, height)
  ihdr.write(Bytes[8, 0, 0, 0, 0])

  output = IO::Memory.new
  output.write(Bytes[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
  write_spec_chunk(output, "IHDR", ihdr.to_slice)
  write_spec_chunk(output, "IDAT", deflate_spec(rows.to_slice))
  write_spec_chunk(output, "IEND", Bytes.empty)
  File.write(path, output.to_slice)
end

private def deflate_spec(data : Bytes) : Bytes
  io = IO::Memory.new
  Compress::Zlib::Writer.open(io) { |zlib| zlib.write(data) }
  io.to_slice
end

private def write_spec_u32(io : IO, value) : Nil
  number = value.to_u32
  io.write_byte(((number >> 24) & 0xff).to_u8)
  io.write_byte(((number >> 16) & 0xff).to_u8)
  io.write_byte(((number >> 8) & 0xff).to_u8)
  io.write_byte((number & 0xff).to_u8)
end

private def write_spec_chunk(output : IO, name : String, payload : Bytes) : Nil
  write_spec_u32(output, payload.size)
  name_bytes = name.to_slice
  output.write(name_bytes)
  output.write(payload)
  crc_input = IO::Memory.new
  crc_input.write(name_bytes)
  crc_input.write(payload)
  write_spec_u32(output, Digest::CRC32.checksum(crc_input.to_slice))
end
