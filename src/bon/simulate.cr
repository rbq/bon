require "compress/zlib"
require "digest/crc32"
require "file_utils"

require "./command"
require "./config"
require "./image"
require "./pdf"
require "./typst"

module Bon
  module Simulate
    alias RGB = Tuple(Int32, Int32, Int32)

    DEFAULT_PPI             = 203
    DEFAULT_MOCKUP_PPI      = 406
    DEFAULT_TOP_MM          = 10.0
    DEFAULT_BOTTOM_MM       = 14.0
    DEFAULT_MIN_TOP_MM      = 12.0
    DEFAULT_MIN_BOTTOM_MM   = 2.0
    DEFAULT_FOREGROUND_FADE = 1.0
    PAPER_RGB               = {245, 241, 224}
    INK_RGB                 = {35, 35, 32}

    class Options
      property format : String
      property paper_mm : Float64
      property printable_width_mm : Float64
      property printable_width_auto : Bool
      property content_mm : Float64?
      property no_crop : Bool
      property ppi : Int32
      property mockup_ppi : Int32
      property top_mm : Float64
      property bottom_mm : Float64
      property min_top_mm : Float64
      property min_bottom_mm : Float64
      property out_dir : String?
      property typst_bin : String
      property background_tint : String
      property foreground_rgb : RGB
      property foreground_fade : Float64

      def initialize(@format = "png",
                     @paper_mm = 80.0,
                     @printable_width_mm = Config.default_printable_width_pt(80.0) * 25.4 / 72.0,
                     @printable_width_auto = true,
                     @content_mm = nil,
                     @no_crop = false,
                     @ppi = DEFAULT_PPI,
                     @mockup_ppi = DEFAULT_MOCKUP_PPI,
                     @top_mm = DEFAULT_TOP_MM,
                     @bottom_mm = DEFAULT_BOTTOM_MM,
                     @min_top_mm = DEFAULT_MIN_TOP_MM,
                     @min_bottom_mm = DEFAULT_MIN_BOTTOM_MM,
                     @out_dir = nil,
                     @typst_bin = "typst",
                     @background_tint = "#f5f1e0",
                     @foreground_rgb = INK_RGB,
                     @foreground_fade = DEFAULT_FOREGROUND_FADE)
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
      raise Error.new("No simulation inputs found") if sources.empty?

      temp_dir = create_temp_dir("bon-simulate-")
      begin
        sources.flat_map { |source| render_source(File.expand_path(source), temp_dir, options, output_io, error_io) }
      ensure
        FileUtils.rm_rf(temp_dir)
      end
    end

    def self.default_sources(cwd = Dir.current) : Array(String)
      ["*.typ", "*.png", "*.jpg", "*.jpeg"].flat_map { |pattern| Dir.glob(File.join(cwd, pattern)) }.sort
    end

    def self.render_source(source : String, temp_dir : String, options : Options, output_io : IO = STDOUT, error_io : IO = STDERR) : Array(String)
      raise Error.new("Simulation input not found: #{source}") unless File.exists?(source)
      raise Error.new("Not a file: #{source}") unless File.file?(source)
      ext = File.extname(source).downcase
      raise Error.new("simulate expects .typ, .png, .jpg, or .jpeg inputs: #{source}") unless supported_input?(ext)

      source_width = physical_source_width_mm(source, ext, options)
      if source_width > options.paper_mm + PDF::CROP_EPSILON_PT * 25.4 / 72.0
        raise Error.new("Input width #{format_mm(source_width)}mm exceeds #{format_mm(options.paper_mm)}mm paper width: #{source}")
      end
      content_width = content_width_mm(source_width, options)
      basename = File.basename(source, ext)
      paper_rgb = parse_rgb(options.background_tint)
      intermediate_pngs = [] of String

      case ext
      when ".typ"
        intermediate_pngs = render_typst_pages(options.typst_bin, source, temp_dir, basename, options.ppi, Typst.root_for(source), output_io, error_io)
      when ".jpg", ".jpeg"
        intermediate_png = File.join(temp_dir, "#{basename}-content.png")
        render_jpeg_to_png(source, intermediate_png, temp_dir, options, output_io, error_io)
        intermediate_pngs << intermediate_png
      else
        intermediate_pngs << source
      end

      multiple_pages = intermediate_pngs.size > 1
      intermediate_pngs.map_with_index(1) do |intermediate_png, page_number|
        output = output_path(source, options, multiple_pages ? page_number : nil)
        FileUtils.mkdir_p(File.dirname(output))
        mockup_png = options.format == "png" ? output : File.join(temp_dir, "#{basename}-mockup-#{page_number}.png")

        simulate_png(intermediate_png, mockup_png, options.paper_mm, content_width, options.mockup_ppi, effective_top_mm(options), effective_bottom_mm(options), seed_for(source) + page_number, source_width, paper_rgb, options.foreground_rgb, options.foreground_fade)
        convert_mockup(options.typst_bin, mockup_png, output, options.format, options.paper_mm, options.mockup_ppi, temp_dir, output_io, error_io) unless options.format == "png"
        output
      end
    end

    def self.output_path(source : String, options : Options, page_number : Int32? = nil) : String
      source_path = File.expand_path(source)
      output_dir = options.out_dir || File.dirname(source_path)
      ext = File.extname(source_path)
      basename = File.basename(source_path, ext)
      basename = "#{basename}-page-#{page_number.to_s.rjust(3, '0')}" if page_number
      File.join(File.expand_path(output_dir), "#{basename}_#{mm_label(options.paper_mm)}mm-printout.#{options.format}")
    end

    def self.simulate_png(source_png : String, output_png : String, paper_mm : Float64, content_width_mm : Float64, mockup_ppi : Int32, top_mm : Float64, bottom_mm : Float64, seed : Int32, source_width_mm : Float64? = nil, paper_rgb = PAPER_RGB, foreground_rgb : RGB = INK_RGB, foreground_fade : Float64 = DEFAULT_FOREGROUND_FADE) : Nil
      source = read_png(source_png)
      densities = source_densities(source)

      paper_width = mm_to_px(paper_mm, mockup_ppi)
      content_width = {paper_width, mm_to_px(content_width_mm, mockup_ppi)}.min
      source_physical_width = source_width_mm || content_width_mm
      crop_ratio = content_width_mm < source_physical_width ? content_width_mm / source_physical_width : 1.0
      crop_width = {source.width, {(source.width * crop_ratio).round.to_i, 1}.max}.min
      crop_x = (source.width - crop_width) // 2
      content_height = {1, (source.height.to_f64 * content_width / crop_width).round.to_i}.max
      top = mm_to_px(top_mm, mockup_ppi)
      bottom = mm_to_px(bottom_mm, mockup_ppi)
      output_height = top + content_height + bottom
      content_x = (paper_width - content_width) // 2

      rgb = Bytes.new(paper_width * output_height * 3)
      output_height.times do |y|
        paper_width.times do |x|
          red, green, blue = paper_pixel(x, y, paper_width, seed, paper_rgb)
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
          sx = crop_x + {crop_width - 1, dx * crop_width // content_width}.min
          density = densities[sy * source.width + sx]
          next if density <= 8

          coverage = {1.0, density / 215.0 * row_band}.min
          threshold = hash_byte(sx, sy, seed + dx // 2) / 255.0
          next if coverage < 0.96 && threshold > coverage

          strength = 0.78 + hash_byte(sx, sy, seed + 131) / 1275.0
          strength = {0.95, coverage * strength * foreground_fade}.min
          x = content_x + dx
          y = top + dy
          offset = (y * paper_width + x) * 3
          base_red = rgb[offset]
          base_green = rgb[offset + 1]
          base_blue = rgb[offset + 2]
          rgb[offset] = blend(base_red, foreground_rgb[0], strength).to_u8
          rgb[offset + 1] = blend(base_green, foreground_rgb[1], strength).to_u8
          rgb[offset + 2] = blend(base_blue, foreground_rgb[2], strength).to_u8
        end
      end

      write_png(output_png, paper_width, output_height, rgb)
    end

    def self.read_png(path : String) : Raster
      raster = Image.read_png(path)
      Raster.new(raster.width, raster.height, raster.channels, raster.pixels)
    end

    def self.parse_rgb(value : String) : Tuple(Int32, Int32, Int32)
      match = value.match(/\A#?([0-9a-fA-F]{2})([0-9a-fA-F]{2})([0-9a-fA-F]{2})\z/)
      raise Error.new("background tint must be a hex RGB color like #f5f1e0") unless match
      {match[1].to_i(16), match[2].to_i(16), match[3].to_i(16)}
    end

    def self.parse_color(value : String) : RGB
      match = value.match(/\A#?([0-9a-fA-F]{6})\z/)
      raise Error.new("foreground color must be a hex RGB value like #232320") unless match

      hex = match[1]
      {hex[0, 2].to_i(16), hex[2, 2].to_i(16), hex[4, 2].to_i(16)}
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

    private def self.paper_pixel(x : Int32, y : Int32, width : Int32, seed : Int32, paper_rgb : Tuple(Int32, Int32, Int32)) : Tuple(Int32, Int32, Int32)
      noise = hash_byte(x, y, seed) - 128
      broad_noise = hash_byte(x // 5, y // 3, seed + 17) - 128
      fiber = hash_byte(x // 19, y, seed + 41) < 7 ? -4 : 0
      edge_shadow = {0, 12 - {x, width - x - 1}.min}.max
      shade = (noise / 32.0 + broad_noise / 42.0).round.to_i + fiber - edge_shadow
      {
        clamp(paper_rgb[0] + shade, 0, 255),
        clamp(paper_rgb[1] + shade, 0, 255),
        clamp(paper_rgb[2] + shade, 0, 255),
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

    private def self.render_typst_pages(typst_bin : String, source : String, temp_dir : String, basename : String, ppi : Int32, root : String, output_io : IO, error_io : IO) : Array(String)
      output_pattern = File.join(temp_dir, "#{basename}-content-{p}.png")
      run_typst(typst_bin, source, output_pattern, "png", ppi, root, output_io, error_io)
      page_pattern = output_pattern.gsub("{p}", "*")
      pages = Dir.glob(page_pattern).sort_by { |path| page_number_from_path(path) || Int32::MAX }
      raise Error.new("Typst simulation render did not produce PNG pages for #{source}") if pages.empty?
      pages
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

    private def self.render_jpeg_to_png(source : String, output : String, temp_dir : String, options : Options, output_io : IO, error_io : IO) : Nil
      size = Image.page_size(source, options.ppi)
      image_name = "source#{File.extname(source).downcase}"
      image_path = File.join(temp_dir, image_name)
      FileUtils.cp(source, image_path) unless File.expand_path(source) == File.expand_path(image_path)
      wrapper = File.join(temp_dir, "#{File.basename(source, File.extname(source))}-image-wrapper.typ")
      File.write(wrapper, String.build do |io|
        io << "#set page(width: #{PDF.format_points(size.width)}pt, height: #{PDF.format_points(size.height)}pt, margin: 0pt)\n"
        io << "#set text(size: 0pt)\n"
        io << "#image(\"#{typst_escape(image_name)}\", width: #{PDF.format_points(size.width)}pt)\n"
      end)
      run_typst(options.typst_bin, wrapper, output, "png", options.ppi, temp_dir, output_io, error_io)
    end

    private def self.physical_source_width_mm(source : String, ext : String, options : Options) : Float64
      if ext == ".typ"
        source_width_mm(source) || options.paper_mm
      else
        Image.page_size(source, options.ppi).width * 25.4 / 72.0
      end
    end

    private def self.content_width_mm(source_width : Float64, options : Options) : Float64
      if content = options.content_mm
        content
      elsif options.no_crop || source_width <= options.printable_width_mm + PDF::CROP_EPSILON_PT * 25.4 / 72.0
        source_width
      else
        options.printable_width_mm
      end
    end

    private def self.supported_input?(ext : String) : Bool
      ext == ".typ" || ext == ".png" || ext == ".jpg" || ext == ".jpeg"
    end

    private def self.typst_escape(path : String) : String
      path.gsub("\\", "\\\\").gsub("\"", "\\\"")
    end

    private def self.format_mm(value : Float64) : String
      formatted = value.round(3).to_s
      formatted.sub(/\.0+$/, "").sub(/(\.\d*?)0+$/, "\\1")
    end

    private def self.page_number_from_path(path : String) : Int32?
      File.basename(path).match(/-(\d+)\.png$/).try { |match| match[1].to_i }
    end

    private def self.effective_top_mm(options : Options) : Float64
      {options.top_mm, options.min_top_mm}.max
    end

    private def self.effective_bottom_mm(options : Options) : Float64
      {options.bottom_mm, options.min_bottom_mm}.max
    end

    private def self.source_width_mm(source : String) : Float64?
      match = File.read(source).match(/\bwidth\s*:\s*([0-9]+(?:\.[0-9]+)?)\s*mm\b/)
      match ? match[1].to_f64 : nil
    end

    private def self.mm_to_px(value : Float64, ppi : Int32) : Int32
      return 0 if value == 0.0

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

    private def self.deflate(data : Bytes) : Bytes
      io = IO::Memory.new
      Compress::Zlib::Writer.open(io) { |zlib| zlib.write(data) }
      io.to_slice
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
