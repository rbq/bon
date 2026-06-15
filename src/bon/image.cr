require "compress/zlib"

require "./command"
require "./config"
require "./pdf"
require "./typst"

module Bon
  module Image
    struct Dimensions
      getter width : Int32
      getter height : Int32

      def initialize(@width : Int32, @height : Int32)
      end
    end

    struct Raster
      getter width : Int32
      getter height : Int32
      getter channels : Int32
      getter pixels : Bytes

      def initialize(@width : Int32, @height : Int32, @channels : Int32, @pixels : Bytes)
      end
    end

    def self.dimensions(path : String) : Dimensions
      ext = File.extname(path).downcase
      case ext
      when ".png"
        png_dimensions(path)
      when ".jpg", ".jpeg"
        jpeg_dimensions(path)
      else
        raise Error.new("Unsupported image type: #{path}")
      end
    end

    def self.page_size(path : String, config : Config) : PDF::PageSize
      page_size(path, config.image_ppi)
    end

    def self.page_size(path : String, ppi : Int32) : PDF::PageSize
      dims = dimensions(path)
      PDF::PageSize.new(
        dims.width.to_f64 / ppi * 72.0,
        dims.height.to_f64 / ppi * 72.0
      )
    end

    def self.downsample_center_crop_to_mono(source : String, output : String, target_width : Int32, target_height : Int32) : Nil
      raise Error.new("Target raster dimensions must be positive") unless target_width > 0 && target_height > 0

      raster = read_png(source)
      crop_width = {(target_width.to_f64 / target_height * raster.height).round.to_i, raster.width}.min
      crop_width = {crop_width, 1}.max
      crop_x = (raster.width - crop_width) // 2
      mono = Bytes.new(target_width * target_height)

      target_height.times do |y|
        y0 = y * raster.height // target_height
        y1 = {raster.height, ((y + 1) * raster.height + target_height - 1) // target_height}.min
        y1 = y0 + 1 if y1 <= y0

        target_width.times do |x|
          x0 = crop_x + x * crop_width // target_width
          x1 = crop_x + {crop_width, ((x + 1) * crop_width + target_width - 1) // target_width}.min
          x1 = x0 + 1 if x1 <= x0

          darkness = 0
          samples = 0
          y0.upto(y1 - 1) do |sy|
            x0.upto(x1 - 1) do |sx|
              darkness += 255 - luminance_at(raster, sx, sy)
              samples += 1
            end
          end

          mono[y * target_width + x] = darkness >= 255 * samples // 8 ? 0_u8 : 255_u8
        end
      end

      PDF.write_mono_png(output, target_width, target_height, mono)
    end

    def self.read_png(path : String) : Raster
      data = File.read(path).to_slice
      raise Error.new("Not a PNG file: #{path}") unless data.size >= 8 && data[0, 8] == Bytes[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]

      offset = 8
      width = 0
      height = 0
      channels = 0
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
          unless bit_depth == 8 && {0_u8, 2_u8, 6_u8}.includes?(color_type) && interlace == 0
            raise Error.new("Only 8-bit, non-interlaced grayscale/RGB/RGBA PNG files are supported: #{path}")
          end
          channels = color_type == 0 ? 1 : (color_type == 2 ? 3 : 4)
        when "IDAT"
          compressed.write(chunk_data)
        when "IEND"
          break
        end
      end

      raise Error.new("PNG is missing an IHDR chunk: #{path}") if width == 0 || height == 0 || channels == 0

      raw = inflate(compressed.to_slice)
      stride = width * channels
      pixels = Bytes.new(width * height * channels)
      previous = Bytes.new(stride)
      pos = 0

      height.times do |row|
        filter_type = raw[pos]
        pos += 1
        reconstructed = Bytes.new(stride)

        stride.times do |i|
          value = raw[pos + i]
          left = i >= channels ? reconstructed[i - channels] : 0_u8
          up = previous[i]
          up_left = i >= channels ? previous[i - channels] : 0_u8
          reconstructed[i] = case filter_type
                             when 0 then value
                             when 1 then ((value.to_i + left.to_i) & 0xff).to_u8
                             when 2 then ((value.to_i + up.to_i) & 0xff).to_u8
                             when 3 then ((value.to_i + ((left.to_i + up.to_i) >> 1)) & 0xff).to_u8
                             when 4 then ((value.to_i + paeth(left.to_i, up.to_i, up_left.to_i)) & 0xff).to_u8
                             else raise Error.new("Unsupported PNG filter type: #{filter_type}")
                             end
        end

        pos += stride
        pixels[row * stride, stride].copy_from(reconstructed)
        previous = reconstructed
      end

      Raster.new(width, height, channels, pixels)
    rescue IndexError
      raise Error.new("Could not read PNG data: #{path}")
    end

    def self.png_dimensions(path : String) : Dimensions
      File.open(path) do |file|
        signature = Bytes.new(8)
        file.read_fully(signature)
        raise Error.new("Invalid PNG signature: #{path}") unless signature == Bytes[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]
        length = file.read_bytes(UInt32, IO::ByteFormat::BigEndian)
        type = Bytes.new(4)
        file.read_fully(type)
        raise Error.new("Invalid PNG IHDR chunk: #{path}") unless length == 13 && String.new(type) == "IHDR"
        width = file.read_bytes(UInt32, IO::ByteFormat::BigEndian)
        height = file.read_bytes(UInt32, IO::ByteFormat::BigEndian)
        Dimensions.new(width.to_i32, height.to_i32)
      end
    rescue IO::EOFError
      raise Error.new("Could not read PNG dimensions: #{path}")
    end

    def self.jpeg_dimensions(path : String) : Dimensions
      File.open(path) do |file|
        raise Error.new("Invalid JPEG signature: #{path}") unless file.read_byte == 0xff && file.read_byte == 0xd8

        loop do
          marker_prefix = file.read_byte
          next if marker_prefix == 0xff
          raise Error.new("Invalid JPEG marker: #{path}") unless marker_prefix

          marker = marker_prefix
          while marker == 0xff
            marker = file.read_byte || raise Error.new("Invalid JPEG marker: #{path}")
          end

          next if marker == 0x01 || (0xd0..0xd9).includes?(marker)
          length = file.read_bytes(UInt16, IO::ByteFormat::BigEndian)
          raise Error.new("Invalid JPEG segment length: #{path}") if length < 2

          if (0xc0..0xc3).includes?(marker) || (0xc5..0xc7).includes?(marker) || (0xc9..0xcb).includes?(marker) || (0xcd..0xcf).includes?(marker)
            file.read_byte
            height = file.read_bytes(UInt16, IO::ByteFormat::BigEndian)
            width = file.read_bytes(UInt16, IO::ByteFormat::BigEndian)
            return Dimensions.new(width.to_i32, height.to_i32)
          end

          file.skip(length - 2)
        end
      end
    rescue IO::EOFError
      raise Error.new("Could not read JPEG dimensions: #{path}")
    end

    def self.wrap_as_typst_pdf(source : String, output : String, temp_dir : String, config : Config, dry_run : Bool, output_io : IO = STDOUT, error_io : IO = STDERR) : Nil
      size = page_size(source, config)
      wrapper = File.join(temp_dir, "image-wrapper.typ")
      File.write(wrapper, String.build do |io|
        io << "#set page(width: #{PDF.format_points(size.width)}pt, height: #{PDF.format_points(size.height)}pt, margin: 0pt)\n"
        io << "#set text(size: 0pt)\n"
        io << "#image(\"#{typst_escape(source)}\", width: #{PDF.format_points(size.width)}pt)\n"
      end)
      Typst.compile(wrapper, output, File.dirname(source), config, dry_run, output_io, error_io)
    end

    private def self.typst_escape(path : String) : String
      path.gsub("\\", "\\\\").gsub("\"", "\\\"")
    end

    private def self.luminance_at(raster : Raster, x : Int32, y : Int32) : Int32
      offset = (y * raster.width + x) * raster.channels
      red = green = blue = 0
      alpha = 255
      case raster.channels
      when 1
        red = green = blue = raster.pixels[offset].to_i
      when 3
        red = raster.pixels[offset].to_i
        green = raster.pixels[offset + 1].to_i
        blue = raster.pixels[offset + 2].to_i
      else
        red = raster.pixels[offset].to_i
        green = raster.pixels[offset + 1].to_i
        blue = raster.pixels[offset + 2].to_i
        alpha = raster.pixels[offset + 3].to_i
      end

      if alpha < 255
        red = (red * alpha + 255 * (255 - alpha)) // 255
        green = (green * alpha + 255 * (255 - alpha)) // 255
        blue = (blue * alpha + 255 * (255 - alpha)) // 255
      end

      (54 * red + 183 * green + 19 * blue) >> 8
    end

    private def self.inflate(data : Bytes) : Bytes
      output = IO::Memory.new
      Compress::Zlib::Reader.open(IO::Memory.new(data)) do |zlib|
        IO.copy(zlib, output)
      end
      output.to_slice
    end

    private def self.read_u32(data : Bytes, offset : Int32) : Int32
      ((data[offset].to_i << 24) | (data[offset + 1].to_i << 16) | (data[offset + 2].to_i << 8) | data[offset + 3].to_i)
    end

    private def self.paeth(left : Int32, up : Int32, up_left : Int32) : Int32
      estimate = left + up - up_left
      dist_left = (estimate - left).abs
      dist_up = (estimate - up).abs
      dist_up_left = (estimate - up_left).abs
      return left if dist_left <= dist_up && dist_left <= dist_up_left
      dist_up <= dist_up_left ? up : up_left
    end
  end
end
