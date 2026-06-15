require "compress/zlib"
require "digest/crc32"
require "file_utils"

require "./command"
require "./config"
require "./typst"

module Bon
  module Simulate
    DEFAULT_PPI = 203
    DEFAULT_MOCKUP_PPI = 406
    PAPER_RGB = {245, 241, 224}
    INK_RGB = {35, 35, 32}

    class Options
      property format : String
      property paper_mm : Float64
      property content_mm : Float64?
      property ppi : Int32
      property mockup_ppi : Int32
      property top_mm : Float64
      property bottom_mm : Float64
      property out_dir : String?
      property typst_bin : String

      def initialize(@format = "png",
                     @paper_mm = 80.0,
                     @content_mm = nil,
                     @ppi = DEFAULT_PPI,
                     @mockup_ppi = DEFAULT_MOCKUP_PPI,
                     @top_mm = 10.0,
                     @bottom_mm = 14.0,
                     @out_dir = nil,
                     @typst_bin = "typst")
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

    def self.render_sources(sources : Array(String), options : Options, output_io : IO = STDOUT, error_io : IO = STDERR) : Array(String)
      raise Error.new("No Typst sources found") if sources.empty?

      temp_dir = create_temp_dir("bon-simulate-")
      begin
        sources.map { |source| render_source(File.expand_path(source), temp_dir, options, output_io, error_io) }
      ensure
        FileUtils.rm_rf(temp_dir)
      end
    end

    def self.default_sources(cwd = Dir.current) : Array(String)
      Dir.glob(File.join(cwd, "*.typ")).sort
    end

    def self.render_source(source : String, temp_dir : String, options : Options, output_io : IO = STDOUT, error_io : IO = STDERR) : String
      raise Error.new("Typst source not found: #{source}") unless File.exists?(source)
      raise Error.new("Not a file: #{source}") unless File.file?(source)
      raise Error.new("simulate expects .typ sources: #{source}") unless File.extname(source).downcase == ".typ"

      source_width = source_width_mm(source) || options.paper_mm
      content_width = options.content_mm || {source_width, options.paper_mm}.min
      output = output_path(source, options)
      FileUtils.mkdir_p(File.dirname(output))
      intermediate_png = File.join(temp_dir, "#{File.basename(source, ".typ")}-content.png")
      mockup_png = options.format == "png" ? output : File.join(temp_dir, "#{File.basename(source, ".typ")}-mockup.png")

      run_typst(options.typst_bin, source, intermediate_png, "png", options.ppi, Typst.root_for(source), output_io, error_io)
      simulate_png(intermediate_png, mockup_png, options.paper_mm, content_width, options.mockup_ppi, options.top_mm, options.bottom_mm, seed_for(source))
      convert_mockup(options.typst_bin, mockup_png, output, options.format, options.paper_mm, options.mockup_ppi, temp_dir, output_io, error_io) unless options.format == "png"
      output
    end

    def self.output_path(source : String, options : Options) : String
      source_path = File.expand_path(source)
      output_dir = options.out_dir || File.dirname(source_path)
      File.join(File.expand_path(output_dir), "#{File.basename(source_path, ".typ")}_#{mm_label(options.paper_mm)}mm-printout.#{options.format}")
    end

    def self.simulate_png(source_png : String, output_png : String, paper_mm : Float64, content_width_mm : Float64, mockup_ppi : Int32, top_mm : Float64, bottom_mm : Float64, seed : Int32) : Nil
      source = read_png(source_png)
      densities = source_densities(source)

      paper_width = mm_to_px(paper_mm, mockup_ppi)
      content_width = {paper_width, mm_to_px(content_width_mm, mockup_ppi)}.min
      content_height = {1, (source.height.to_f64 * content_width / source.width).round.to_i}.max
      top = mm_to_px(top_mm, mockup_ppi)
      bottom = mm_to_px(bottom_mm, mockup_ppi)
      output_height = top + content_height + bottom
      content_x = (paper_width - content_width) // 2

      rgb = Bytes.new(paper_width * output_height * 3)
      output_height.times do |y|
        paper_width.times do |x|
          red, green, blue = paper_pixel(x, y, paper_width, seed)
          offset = (y * paper_width + x) * 3
          rgb[offset] = red.to_u8
          rgb[offset + 1] = green.to_u8
          rgb[offset + 2] = blue.to_u8
        end
      end

      content_height.times do |dy|
        sy = {source.height - 1, dy * source.height // content_height}.min
        row_band = 0.93 + hash_byte(0, sy, seed + 73) / 1275.0
        row_band *= 0.88 if sy % 24 == 0

        content_width.times do |dx|
          sx = {source.width - 1, dx * source.width // content_width}.min
          density = densities[sy * source.width + sx]
          next if density <= 8

          coverage = {1.0, density / 215.0 * row_band}.min
          threshold = hash_byte(sx, sy, seed + dx // 2) / 255.0
          next if coverage < 0.96 && threshold > coverage

          strength = 0.78 + hash_byte(sx, sy, seed + 131) / 1275.0
          strength = {0.95, coverage * strength}.min
          x = content_x + dx
          y = top + dy
          offset = (y * paper_width + x) * 3
          base_red = rgb[offset]
          base_green = rgb[offset + 1]
          base_blue = rgb[offset + 2]
          rgb[offset] = blend(base_red, INK_RGB[0], strength).to_u8
          rgb[offset + 1] = blend(base_green, INK_RGB[1], strength).to_u8
          rgb[offset + 2] = blend(base_blue, INK_RGB[2], strength).to_u8
        end
      end

      write_png(output_png, paper_width, output_height, rgb)
    end

    def self.read_png(path : String) : Raster
      data = File.read(path).to_slice
      raise Error.new("Not a PNG file: #{path}") unless data[0, 8] == Bytes[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]

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
            raise Error.new("Only 8-bit, non-interlaced grayscale/RGB/RGBA PNG files are supported")
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
        start = row * stride
        pixels[start, stride].copy_from(reconstructed)
        previous = reconstructed
      end

      Raster.new(width, height, channels, pixels)
    end

    def self.write_png(path : String, width : Int32, height : Int32, rgb : Bytes) : Nil
      rows = IO::Memory.new
      stride = width * 3
      height.times do |row|
        rows.write_byte(0_u8)
        rows.write(rgb[row * stride, stride])
      end

      ihdr = IO::Memory.new
      write_u32(ihdr, width)
      write_u32(ihdr, height)
      ihdr.write(Bytes[8, 2, 0, 0, 0])

      output = IO::Memory.new
      output.write(Bytes[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
      write_chunk(output, "IHDR", ihdr.to_slice)
      write_chunk(output, "IDAT", deflate(rows.to_slice))
      write_chunk(output, "IEND", Bytes.empty)
      File.write(path, output.to_slice)
    end

    private def self.source_densities(source : Raster) : Bytes
      densities = Bytes.new(source.width * source.height)
      (source.width * source.height).times do |index|
        offset = index * source.channels
        red = green = blue = 0
        alpha = 255
        case source.channels
        when 1
          red = green = blue = source.pixels[offset].to_i
        when 3
          red = source.pixels[offset].to_i
          green = source.pixels[offset + 1].to_i
          blue = source.pixels[offset + 2].to_i
        else
          red = source.pixels[offset].to_i
          green = source.pixels[offset + 1].to_i
          blue = source.pixels[offset + 2].to_i
          alpha = source.pixels[offset + 3].to_i
        end

        if alpha < 255
          red = (red * alpha + 255 * (255 - alpha)) // 255
          green = (green * alpha + 255 * (255 - alpha)) // 255
          blue = (blue * alpha + 255 * (255 - alpha)) // 255
        end

        luminance = (54 * red + 183 * green + 19 * blue) >> 8
        density = clamp(((246 - luminance) * 255 / 210.0).round.to_i, 0, 255)
        density = {255, ((density / 255.0) ** 0.85 * 255).round.to_i}.min if density > 0
        densities[index] = density.to_u8
      end

      spread = Bytes.new(densities.size)
      spread.copy_from(densities)
      source.height.times do |y|
        source.width.times do |x|
          index = y * source.width + x
          neighbor = 0
          (y - 1).upto(y + 1) do |ny|
            next if ny < 0 || ny >= source.height
            row_start = ny * source.width
            (x - 1).upto(x + 1) do |nx|
              next if nx < 0 || nx >= source.width || (nx == x && ny == y)
              neighbor = {neighbor, densities[row_start + nx].to_i}.max
            end
          end
          spread[index] = {spread[index].to_i, (neighbor * 0.10).round.to_i}.max.to_u8
        end
      end
      spread
    end

    private def self.paper_pixel(x : Int32, y : Int32, width : Int32, seed : Int32) : Tuple(Int32, Int32, Int32)
      noise = hash_byte(x, y, seed) - 128
      broad_noise = hash_byte(x // 5, y // 3, seed + 17) - 128
      fiber = hash_byte(x // 19, y, seed + 41) < 7 ? -4 : 0
      edge_shadow = {0, 12 - {x, width - x - 1}.min}.max
      shade = (noise / 32.0 + broad_noise / 42.0).round.to_i + fiber - edge_shadow
      {
        clamp(PAPER_RGB[0] + shade, 0, 255),
        clamp(PAPER_RGB[1] + shade, 0, 255),
        clamp(PAPER_RGB[2] + shade, 0, 255),
      }
    end

    private def self.convert_mockup(typst_bin : String, mockup_png : String, output : String, format : String, paper_mm : Float64, ppi : Int32, temp_dir : String, output_io : IO, error_io : IO) : Nil
      raster = read_png(mockup_png)
      height_mm = raster.height.to_f64 / ppi * 25.4
      wrapper = File.join(temp_dir, "mockup-wrapper.typ")
      File.write(wrapper, String.build do |io|
        io << "#set page(width: #{paper_mm}mm, height: #{height_mm}mm, margin: 0mm)\n"
        io << "#image(\"#{File.basename(mockup_png).gsub("\\", "\\\\").gsub("\"", "\\\"")}\", width: #{paper_mm}mm)\n"
      end)
      run_typst(typst_bin, wrapper, output, format, ppi, temp_dir, output_io, error_io)
    end

    private def self.run_typst(typst_bin : String, input : String, output : String, format : String, ppi : Int32, root : String, output_io : IO, error_io : IO) : Nil
      typst = typst_bin.includes?(File::SEPARATOR) ? typst_bin : Command.require_executable(typst_bin)
      Command.run([
        typst,
        "compile",
        "--root",
        root,
        "--ppi",
        ppi.to_s,
        "-f",
        format,
        input,
        output,
      ], "Typst simulation render failed for #{input}", false, false, output_io, error_io)
    end

    private def self.source_width_mm(source : String) : Float64?
      match = File.read(source).match(/\bwidth\s*:\s*([0-9]+(?:\.[0-9]+)?)\s*mm\b/)
      match ? match[1].to_f64 : nil
    end

    private def self.mm_to_px(value : Float64, ppi : Int32) : Int32
      {1, (value / 25.4 * ppi).round.to_i}.max
    end

    private def self.mm_label(value : Float64) : String
      value == value.round ? value.to_i.to_s : value.to_s.sub(/0+$/, "").sub(/\.$/, "").gsub('.', 'p')
    end

    private def self.seed_for(source : String) : Int32
      seed = 0
      File.basename(source, File.extname(source)).each_byte { |byte| seed += byte }
      seed
    end

    private def self.hash_byte(x : Int32, y : Int32, seed : Int32) : Int32
      value = (x.to_u64 * 374761393_u64 + y.to_u64 * 668265263_u64 + seed.to_u64 * 2246822519_u64) & 0xffffffff_u64
      value = (value ^ (value >> 13)) & 0xffffffff_u64
      value = (value * 1274126177_u64) & 0xffffffff_u64
      value = (value ^ (value >> 16)) & 0xffffffff_u64
      (value & 0xff_u64).to_i
    end

    private def self.paeth(left : Int32, up : Int32, up_left : Int32) : Int32
      estimate = left + up - up_left
      dist_left = (estimate - left).abs
      dist_up = (estimate - up).abs
      dist_up_left = (estimate - up_left).abs
      return left if dist_left <= dist_up && dist_left <= dist_up_left
      dist_up <= dist_up_left ? up : up_left
    end

    private def self.inflate(data : Bytes) : Bytes
      text = Compress::Zlib::Reader.open(IO::Memory.new(data)) { |zlib| zlib.gets_to_end }
      text.to_slice
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

    private def self.blend(base : UInt8, ink : Int32, strength : Float64) : Int32
      (base.to_i * (1 - strength) + ink * strength).round.to_i
    end

    private def self.clamp(value : Int32, minimum : Int32, maximum : Int32) : Int32
      {minimum, {value, maximum}.min}.max
    end

    private def self.create_temp_dir(prefix : String) : String
      base = Dir.tempdir
      100.times do
        candidate = File.join(base, "#{prefix}#{Process.pid}-#{Time.utc.to_unix_ns}-#{Random.rand(1_000_000)}")
        unless Dir.exists?(candidate) || File.exists?(candidate)
          Dir.mkdir(candidate)
          return candidate
        end
      end
      raise Error.new("Could not create temporary directory")
    end
  end
end
