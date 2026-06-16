require "compress/zlib"
require "digest/crc32"

require "./command"
require "./config"

module Bon
  module PDF
    CROP_EPSILON_PT = 0.1
    BOX_PATTERN     = /\/(?:CropBox|MediaBox)\s*\[\s*([-+]?\d*\.?\d+)\s+([-+]?\d*\.?\d+)\s+([-+]?\d*\.?\d+)\s+([-+]?\d*\.?\d+)\s*\]/

    struct PageSize
      getter width : Float64
      getter height : Float64

      def initialize(@width : Float64, @height : Float64)
      end
    end

    struct PrintReady
      getter path : String
      getter size : PageSize

      def initialize(@path : String, @size : PageSize)
      end
    end

    struct GrayscaleRaster
      getter width : Int32
      getter height : Int32
      getter pixels : Bytes

      def initialize(@width : Int32, @height : Int32, @pixels : Bytes)
      end
    end

    def self.first_page_size(path : String) : PageSize
      page_sizes(path).first
    end

    def self.page_sizes(path : String) : Array(PageSize)
      data = ascii_projection(File.read(path))
      sizes = [] of PageSize
      data.scan(BOX_PATTERN) do |match|
        left = match[1].to_f64
        bottom = match[2].to_f64
        right = match[3].to_f64
        top = match[4].to_f64
        width = (right - left).abs
        height = (top - bottom).abs
        sizes << PageSize.new(width, height) if width > 0 && height > 0
      end
      raise Error.new("Could not determine PDF page size from #{path}") if sizes.empty?
      sizes
    end

    def self.print_size(path : String) : PageSize
      sizes = page_sizes(path)
      PageSize.new(sizes.max_of(&.width), sizes.max_of(&.height))
    end

    private def self.ascii_projection(data : String) : String
      String.build do |io|
        data.each_byte do |byte|
          io.write_byte(byte < 128 ? byte : 32_u8)
        end
      end
    end

    def self.ensure_width_policy(path : String, output : String, config : Config, no_crop : Bool, dry_run : Bool, output_io : IO = STDOUT, error_io : IO = STDERR) : String
      size = print_size(path)
      if size.width > config.paper_width_pt + CROP_EPSILON_PT
        raise Error.new("PDF width #{format_points(size.width)}pt exceeds #{format_points(config.paper_width_pt)}pt paper width: #{path}")
      end

      return path if no_crop || size.width <= config.printable_width_pt + CROP_EPSILON_PT
      crop_to_width(path, output, config.printable_width_pt, dry_run, output_io, error_io)
    end

    def self.prepare_for_print(path : String, output : String, config : Config, no_crop : Bool, dry_run : Bool, output_io : IO = STDOUT, error_io : IO = STDERR) : PrintReady
      size = print_size(path)
      if size.width > config.paper_width_pt + CROP_EPSILON_PT
        raise Error.new("PDF width #{format_points(size.width)}pt exceeds #{format_points(config.paper_width_pt)}pt paper width: #{path}")
      end

      return PrintReady.new(path, size) if no_crop || size.width <= config.printable_width_pt + CROP_EPSILON_PT

      target_size = PageSize.new(config.printable_width_pt, size.height)
      crop_to_width(path, output, config.printable_width_pt, dry_run, output_io, error_io)
      PrintReady.new(output, target_size)
    end

    def self.prepare_pages_for_print(path : String, output_prefix : String, config : Config, no_crop : Bool, dry_run : Bool, output_io : IO = STDOUT, error_io : IO = STDERR) : Array(PrintReady)
      sizes = page_sizes(path)
      max_width = sizes.max_of(&.width)
      if max_width > config.paper_width_pt + CROP_EPSILON_PT
        raise Error.new("PDF width #{format_points(max_width)}pt exceeds #{format_points(config.paper_width_pt)}pt paper width: #{path}")
      end

      if sizes.size == 1
        return [prepare_for_print(path, "#{output_prefix}.pdf", config, no_crop, dry_run, output_io, error_io)]
      end

      crop = !no_crop && max_width > config.printable_width_pt + CROP_EPSILON_PT
      sizes.map_with_index do |size, index|
        page_number = index + 1
        output = "#{output_prefix}-page-#{page_number.to_s.rjust(3, '0')}.pdf"
        if crop
          target_size = PageSize.new(config.printable_width_pt, size.height)
          crop_page_to_width(path, output, config.printable_width_pt, page_number, size, dry_run, output_io, error_io)
          PrintReady.new(output, target_size)
        else
          split_page(path, output, page_number, dry_run, output_io, error_io)
          PrintReady.new(output, size)
        end
      end
    end

    def self.crop_to_width(source : String, output : String, target_width : Float64, dry_run : Bool, output_io : IO = STDOUT, error_io : IO = STDERR) : String
      size = print_size(source)
      left_crop = (size.width - target_width) / 2.0
      gs = Command.require_executable("gs")
      Command.run([
        gs,
        "-q",
        "-dNOPAUSE",
        "-dBATCH",
        "-sDEVICE=pdfwrite",
        "-dCompatibilityLevel=1.7",
        "-dDEVICEWIDTHPOINTS=#{format_points(target_width)}",
        "-dDEVICEHEIGHTPOINTS=#{format_points(size.height)}",
        "-dFIXEDMEDIA",
        "-sOutputFile=#{output}",
        "-c",
        "<</PageOffset [#{format_points(-left_crop)} 0]>> setpagedevice",
        "-f",
        source,
      ], "PDF media crop failed for #{source}", dry_run, true, output_io, error_io)
      output
    end

    def self.split_page(source : String, output : String, page_number : Int32, dry_run : Bool, output_io : IO = STDOUT, error_io : IO = STDERR) : String
      gs = Command.require_executable("gs")
      Command.run([
        gs,
        "-q",
        "-dNOPAUSE",
        "-dBATCH",
        "-sDEVICE=pdfwrite",
        "-dCompatibilityLevel=1.7",
        "-dFirstPage=#{page_number}",
        "-dLastPage=#{page_number}",
        "-sOutputFile=#{output}",
        source,
      ], "PDF page extraction failed for #{source} page #{page_number}", dry_run, false, output_io, error_io)
      output
    end

    def self.crop_page_to_width(source : String, output : String, target_width : Float64, page_number : Int32, size : PageSize, dry_run : Bool, output_io : IO = STDOUT, error_io : IO = STDERR) : String
      left_crop = (size.width - target_width) / 2.0
      gs = Command.require_executable("gs")
      Command.run([
        gs,
        "-q",
        "-dNOPAUSE",
        "-dBATCH",
        "-sDEVICE=pdfwrite",
        "-dCompatibilityLevel=1.7",
        "-dFirstPage=#{page_number}",
        "-dLastPage=#{page_number}",
        "-dDEVICEWIDTHPOINTS=#{format_points(target_width)}",
        "-dDEVICEHEIGHTPOINTS=#{format_points(size.height)}",
        "-dFIXEDMEDIA",
        "-sOutputFile=#{output}",
        "-c",
        "<</PageOffset [#{format_points(-left_crop)} 0]>> setpagedevice",
        "-f",
        source,
      ], "PDF media crop failed for #{source} page #{page_number}", dry_run, false, output_io, error_io)
      output
    end

    def self.crop_to_raster(source : String, output : String, source_size : PageSize, target_size : PageSize, ppi : Int32, multiplier : Int32, dry_run : Bool, output_io : IO = STDOUT, error_io : IO = STDERR, threshold = 0.125, dither = "none") : String
      gs = Command.require_executable("gs")
      if multiplier <= 1
        Command.run(
          raster_crop_command(gs, source, output, source_size, target_size, ppi),
          "PDF raster crop failed for #{source}",
          dry_run,
          true,
          output_io,
          error_io
        )
        return output
      end

      high_ppi = ppi * multiplier
      high_output = high_resolution_path(output, high_ppi)
      Command.run(
        raster_crop_command(gs, source, high_output, source_size, target_size, high_ppi, grayscale: true),
        "PDF raster crop failed for #{source}",
        dry_run,
        true,
        output_io,
        error_io
      )
      downsample_grayscale_to_mono(high_output, output, multiplier, threshold, dither) if File.exists?(high_output)
      output
    end

    def self.raster_crop_command(gs : String, source : String, output : String, source_size : PageSize, target_size : PageSize, ppi : Int32, grayscale = false) : Array(String)
      left_crop = (source_size.width - target_size.width) / 2.0
      [
        gs,
        "-q",
        "-dNOPAUSE",
        "-dBATCH",
        "-sDEVICE=#{grayscale ? "pnggray" : "pngmono"}",
        "-r#{ppi}x#{ppi}",
        "-dTextAlphaBits=#{grayscale ? 4 : 1}",
        "-dGraphicsAlphaBits=#{grayscale ? 4 : 1}",
        "-dDEVICEWIDTHPOINTS=#{format_points(target_size.width)}",
        "-dDEVICEHEIGHTPOINTS=#{format_points(target_size.height)}",
        "-dFIXEDMEDIA",
        "-sOutputFile=#{output}",
        "-c",
        "<</PageOffset [#{format_points(-left_crop)} 0]>> setpagedevice",
        "-f",
        source,
      ]
    end

    def self.downsample_grayscale_to_mono(source : String, output : String, multiplier : Int32, threshold = 0.125, dither = "none") : Nil
      raster = read_grayscale_png(source)
      unless raster.width % multiplier == 0 && raster.height % multiplier == 0
        raise Error.new("High-resolution raster size #{raster.width}x#{raster.height}px is not divisible by raster_ppi_multiplier=#{multiplier}")
      end

      target_width = raster.width // multiplier
      target_height = raster.height // multiplier
      samples = multiplier * multiplier
      mono = Bytes.new(target_width * target_height)

      target_height.times do |y|
        target_width.times do |x|
          darkness = 0
          multiplier.times do |dy|
            source_row = (y * multiplier + dy) * raster.width
            multiplier.times do |dx|
              darkness += 255 - raster.pixels[source_row + x * multiplier + dx].to_i
            end
          end
          mono[y * target_width + x] = threshold_to_mono(darkness, samples, x, y, threshold, dither)
        end
      end

      write_mono_png(output, target_width, target_height, mono)
    end

    def self.threshold_to_mono(darkness : Int32, samples : Int32, x : Int32, y : Int32, threshold : Float64, dither : String) : UInt8
      coverage = darkness.to_f64 / (255.0 * samples)
      cutoff = dither == "ordered" ? ordered_cutoff(threshold, x, y) : threshold
      coverage >= cutoff ? 0_u8 : 255_u8
    end

    def self.points_to_pixels(points : Float64, ppi : Int32) : Int32
      {1, (points / 72.0 * ppi).round.to_i}.max
    end

    def self.pixels_to_points(pixels : Int32, ppi : Int32) : Float64
      pixels.to_f64 / ppi * 72.0
    end

    def self.format_points(value : Float64) : String
      formatted = value.round(3).to_s
      formatted = formatted.sub(/\.0+$/, "").sub(/(\.\d*?)0+$/, "\\1")
      formatted
    end

    private def self.high_resolution_path(output : String, ppi : Int32) : String
      ext = File.extname(output)
      base = ext.empty? ? output : output[0...-ext.size]
      "#{base}-#{ppi}ppi#{ext.empty? ? ".png" : ext}"
    end

    private def self.ordered_cutoff(threshold : Float64, x : Int32, y : Int32) : Float64
      matrix = {
        {0, 8, 2, 10},
        {12, 4, 14, 6},
        {3, 11, 1, 9},
        {15, 7, 13, 5},
      }
      offset = ((matrix[y % 4][x % 4] + 0.5) / 16.0) - 0.5
      (threshold + offset).clamp(0.0, 1.0)
    end

    private def self.read_grayscale_png(path : String) : GrayscaleRaster
      data = File.read(path).to_slice
      raise Error.new("Not a PNG file: #{path}") unless data.size >= 8 && data[0, 8] == Bytes[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]

      offset = 8
      width = 0
      height = 0
      bit_depth = 0_u8
      color_type = 0_u8
      compressed = IO::Memory.new

      while offset < data.size
        length = read_u32(data, offset)
        chunk_type = String.new(data[offset + 4, 4])
        chunk_data = data[offset + 8, length]
        offset += 12 + length

        case chunk_type
        when "IHDR"
          width = read_u32(chunk_data, 0)
          height = read_u32(chunk_data, 4)
          bit_depth = chunk_data[8]
          color_type = chunk_data[9]
          interlace = chunk_data[12]
          unless bit_depth == 8 && color_type == 0 && interlace == 0
            raise Error.new("Expected an 8-bit, non-interlaced grayscale PNG from Ghostscript: #{path}")
          end
        when "IDAT"
          compressed.write(chunk_data)
        when "IEND"
          break
        end
      end

      raise Error.new("PNG is missing an IHDR chunk: #{path}") if width == 0 || height == 0 || bit_depth == 0_u8
      raw = inflate(compressed.to_slice)
      stride = width
      pixels = Bytes.new(width * height)
      previous = Bytes.new(stride)
      pos = 0

      height.times do |row|
        filter_type = raw[pos]
        pos += 1
        reconstructed = Bytes.new(stride)

        stride.times do |i|
          value = raw[pos + i]
          left = i >= 1 ? reconstructed[i - 1] : 0_u8
          up = previous[i]
          up_left = i >= 1 ? previous[i - 1] : 0_u8
          reconstructed[i] = case filter_type
                             when 0 then value
                             when 1 then ((value.to_i + left.to_i) & 0xff).to_u8
                             when 2 then ((value.to_i + up.to_i) & 0xff).to_u8
                             when 3 then ((value.to_i + ((left.to_i + up.to_i) >> 1)) & 0xff).to_u8
                             when 4 then ((value.to_i + paeth(left.to_i, up.to_i, up_left.to_i)) & 0xff).to_u8
                             else        raise Error.new("Unsupported PNG filter type: #{filter_type}")
                             end
        end

        pos += stride
        pixels[row * stride, stride].copy_from(reconstructed)
        previous = reconstructed
      end

      GrayscaleRaster.new(width, height, pixels)
    rescue IndexError
      raise Error.new("Could not read grayscale PNG data: #{path}")
    end

    def self.write_mono_png(path : String, width : Int32, height : Int32, grayscale : Bytes) : Nil
      row_bytes = (width + 7) // 8
      rows = IO::Memory.new
      height.times do |y|
        rows.write_byte(0_u8)
        row_bytes.times do |byte_index|
          byte = 0
          8.times do |bit|
            x = byte_index * 8 + bit
            white = x >= width || grayscale[y * width + x] >= 128
            byte |= 1 << (7 - bit) if white
          end
          rows.write_byte(byte.to_u8)
        end
      end

      ihdr = IO::Memory.new
      write_u32(ihdr, width)
      write_u32(ihdr, height)
      ihdr.write(Bytes[1, 0, 0, 0, 0])

      output = IO::Memory.new
      output.write(Bytes[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
      write_chunk(output, "IHDR", ihdr.to_slice)
      write_chunk(output, "IDAT", deflate(rows.to_slice))
      write_chunk(output, "IEND", Bytes.empty)
      File.write(path, output.to_slice)
    end

    private def self.inflate(data : Bytes) : Bytes
      output = IO::Memory.new
      Compress::Zlib::Reader.open(IO::Memory.new(data)) do |zlib|
        IO.copy(zlib, output)
      end
      output.to_slice
    end

    private def self.deflate(data : Bytes) : Bytes
      io = IO::Memory.new
      Compress::Zlib::Writer.open(io) { |zlib| zlib.write(data) }
      io.to_slice
    end

    private def self.read_u32(data : Bytes, offset : Int32) : Int32
      ((data[offset].to_i << 24) | (data[offset + 1].to_i << 16) | (data[offset + 2].to_i << 8) | data[offset + 3].to_i)
    end

    private def self.write_u32(io : IO, value) : Nil
      number = value.to_u32
      io.write_byte(((number >> 24) & 0xff).to_u8)
      io.write_byte(((number >> 16) & 0xff).to_u8)
      io.write_byte(((number >> 8) & 0xff).to_u8)
      io.write_byte((number & 0xff).to_u8)
    end

    private def self.write_chunk(output : IO, name : String, payload : Bytes) : Nil
      write_u32(output, payload.size)
      name_bytes = name.to_slice
      output.write(name_bytes)
      output.write(payload)
      crc_input = IO::Memory.new
      crc_input.write(name_bytes)
      crc_input.write(payload)
      write_u32(output, Digest::CRC32.checksum(crc_input.to_slice))
    end

    private def self.paeth(left : Int32, up : Int32, up_left : Int32) : Int32
      estimate = left + up - up_left
      dist_left = (estimate - left).abs
      dist_up = (estimate - up).abs
      dist_up_left = (estimate - up_left).abs
      return left if dist_left <= dist_up && dist_left <= dist_up_left
      dist_up <= dist_up_left ? up : up_left
    end

    def self.verify_png_size(path : String, expected_width : Int32, expected_height : Int32) : Nil
      File.open(path) do |file|
        signature = Bytes.new(8)
        file.read_fully(signature)
        raise Error.new("Invalid rasterized PNG signature: #{path}") unless signature == Bytes[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]
        length = file.read_bytes(UInt32, IO::ByteFormat::BigEndian)
        type = Bytes.new(4)
        file.read_fully(type)
        raise Error.new("Invalid rasterized PNG IHDR chunk: #{path}") unless length == 13 && String.new(type) == "IHDR"
        width = file.read_bytes(UInt32, IO::ByteFormat::BigEndian).to_i32
        height = file.read_bytes(UInt32, IO::ByteFormat::BigEndian).to_i32
        unless width == expected_width && height == expected_height
          raise Error.new("Rasterized print image is #{width}x#{height}px; expected #{expected_width}x#{expected_height}px at printer resolution")
        end
      end
    rescue IO::EOFError
      raise Error.new("Could not read rasterized PNG dimensions: #{path}")
    end
  end
end
