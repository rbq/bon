require "./config"
require "./image"
require "./latex"
require "./pdf"
require "./typst"

module Bon
  module Document
    SUPPORTED_SUFFIXES = [".pdf", ".png", ".jpg", ".jpeg", ".typ", ".tex"]

    struct Prepared
      getter pages : Array(PDF::PrintReady)

      def initialize(@pages : Array(PDF::PrintReady))
      end

      def initialize(path : String, size : PDF::PageSize)
        @pages = [PDF::PrintReady.new(path, size)]
      end

      def path : String
        @pages.first.path
      end

      def size : PDF::PageSize
        @pages.first.size
      end
    end

    def self.prepare(source : String, temp_dir : String, index : Int32, config : Config, no_crop : Bool, dry_run : Bool, output_io : IO = STDOUT, error_io : IO = STDERR) : Prepared
      path = File.expand_path(source)
      validate(path)
      ext = File.extname(path).downcase

      if image?(ext)
        return prepare_image(path, temp_dir, index, config, no_crop, dry_run, output_io, error_io)
      end

      if ext == ".typ"
        return prepare_typst(path, temp_dir, index, config, no_crop, dry_run, output_io, error_io)
      end

      pdf = prepare_pdf(path, temp_dir, index, config, dry_run, output_io, error_io)
      pages = PDF.prepare_pages_for_print(
        pdf,
        File.join(temp_dir, "#{index.to_s.rjust(3, '0')}-#{File.basename(path, ext)}-print"),
        config,
        no_crop,
        dry_run,
        output_io,
        error_io
      )
      Prepared.new(pages)
    end

    def self.prepare_pdf(source : String, temp_dir : String, index : Int32, config : Config, dry_run : Bool, output_io : IO = STDOUT, error_io : IO = STDERR) : String
      path = File.expand_path(source)
      validate(path)
      ext = File.extname(path).downcase
      return path if ext == ".pdf"

      output = File.join(temp_dir, "#{index.to_s.rjust(3, '0')}-#{File.basename(path, ext)}.pdf")
      case ext
      when ".typ"
        Typst.compile(path, output, Typst.root_for(path), config, dry_run, output_io, error_io)
      when ".png", ".jpg", ".jpeg"
        Image.wrap_as_typst_pdf(path, output, temp_dir, config, dry_run, output_io, error_io)
      when ".tex"
        Latex.compile(path, output, temp_dir, config, dry_run, output_io, error_io)
      else
        raise Error.new("Unsupported input type for #{path}; expected one of: #{SUPPORTED_SUFFIXES.join(", ")}")
      end
      output
    end

    private def self.prepare_image(path : String, temp_dir : String, index : Int32, config : Config, no_crop : Bool, dry_run : Bool, output_io : IO, error_io : IO) : Prepared
      size = Image.page_size(path, config)
      if size.width > config.paper_width_pt + PDF::CROP_EPSILON_PT
        raise Error.new("Image width #{PDF.format_points(size.width)}pt exceeds #{PDF.format_points(config.paper_width_pt)}pt paper width: #{path}")
      end

      return Prepared.new(path, size) if no_crop || size.width <= config.printable_width_pt + PDF::CROP_EPSILON_PT

      ext = File.extname(path).downcase
      pdf = File.join(temp_dir, "#{index.to_s.rjust(3, '0')}-#{File.basename(path, ext)}.pdf")
      Image.wrap_as_typst_pdf(path, pdf, temp_dir, config, dry_run, output_io, error_io)
      pages = PDF.prepare_pages_for_print(
        pdf,
        File.join(temp_dir, "#{index.to_s.rjust(3, '0')}-#{File.basename(path, ext)}-print"),
        config,
        false,
        dry_run,
        output_io,
        error_io
      )
      Prepared.new(pages)
    end

    private def self.prepare_typst(path : String, temp_dir : String, index : Int32, config : Config, no_crop : Bool, dry_run : Bool, output_io : IO, error_io : IO) : Prepared
      return prepare_typst_raster(path, temp_dir, index, config, no_crop, dry_run, output_io, error_io) if config.typst_mode == "raster"

      basename = File.basename(path, ".typ")
      pdf = File.join(temp_dir, "#{index.to_s.rjust(3, '0')}-#{basename}.pdf")
      Typst.compile(path, pdf, Typst.root_for(path), config, dry_run, output_io, error_io)

      return Prepared.new(pdf, PDF::PageSize.new(1, 1)) unless File.exists?(pdf)

      pages = PDF.prepare_pages_for_print(
        pdf,
        File.join(temp_dir, "#{index.to_s.rjust(3, '0')}-#{basename}-print"),
        config,
        no_crop,
        dry_run,
        output_io,
        error_io
      )
      Prepared.new(pages)
    end

    private def self.prepare_typst_raster(path : String, temp_dir : String, index : Int32, config : Config, no_crop : Bool, dry_run : Bool, output_io : IO, error_io : IO) : Prepared
      basename = File.basename(path, ".typ")
      high_ppi = config.image_ppi * config.raster_ppi_multiplier
      raster = File.join(temp_dir, "#{index.to_s.rjust(3, '0')}-#{basename}-typst-#{high_ppi}ppi.png")
      Typst.compile_png(path, raster, Typst.root_for(path), high_ppi, config, dry_run, output_io, error_io)

      return Prepared.new(raster, PDF::PageSize.new(1, 1)) unless File.exists?(raster)

      size = Image.page_size(raster, high_ppi)
      if size.width > config.paper_width_pt + PDF::CROP_EPSILON_PT
        raise Error.new("Typst page width #{PDF.format_points(size.width)}pt exceeds #{PDF.format_points(config.paper_width_pt)}pt paper width: #{path}")
      end

      target_width = no_crop || size.width <= config.printable_width_pt + PDF::CROP_EPSILON_PT ? size.width : config.printable_width_pt
      target_width_px = PDF.points_to_pixels(target_width, config.image_ppi)
      target_height_px = PDF.points_to_pixels(size.height, config.image_ppi)
      output = File.join(temp_dir, "#{index.to_s.rjust(3, '0')}-#{basename}-print.png")
      Image.downsample_center_crop_to_mono(raster, output, target_width_px, target_height_px)
      PDF.verify_png_size(output, target_width_px, target_height_px)

      Prepared.new(output, PDF::PageSize.new(
        PDF.pixels_to_points(target_width_px, config.image_ppi),
        PDF.pixels_to_points(target_height_px, config.image_ppi)
      ))
    end

    private def self.image?(ext : String) : Bool
      ext == ".png" || ext == ".jpg" || ext == ".jpeg"
    end

    def self.validate(path : String) : Nil
      raise Error.new("Input file not found: #{path}") unless File.exists?(path)
      raise Error.new("Not a file: #{path}") unless File.file?(path)
      ext = File.extname(path).downcase
      unless SUPPORTED_SUFFIXES.includes?(ext)
        raise Error.new("Unsupported input type for #{path}; expected one of: #{SUPPORTED_SUFFIXES.join(", ")}")
      end
    end
  end
end
