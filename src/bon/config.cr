module Bon
  alias TomlScalar = String | Bool | Int64 | Float64 | Array(String)

  module Toml
    def self.parse_file(path : String) : Hash(String, TomlScalar)
      parse(File.read(path), path)
    end

    def self.parse(text : String, source = "config") : Hash(String, TomlScalar)
      values = Hash(String, TomlScalar).new
      table = [] of String

      text.each_line.with_index(1) do |line, number|
        stripped = strip_comment(line).strip
        next if stripped.empty?

        if stripped.starts_with?("[") && stripped.ends_with?("]")
          name = stripped[1...-1].strip
          raise Error.new("Invalid empty TOML table in #{source}:#{number}") if name.empty?
          table = split_key(name, source, number)
          next
        end

        key, separator, raw_value = stripped.partition("=")
        raise Error.new("Invalid TOML assignment in #{source}:#{number}") if separator.empty?
        full_key = (table + split_key(key.strip, source, number)).join(".")
        values[full_key] = parse_value(raw_value.strip, source, number)
      end

      values
    end

    private def self.strip_comment(line : String) : String
      in_string = false
      escaped = false
      line.each_char.with_index do |char, index|
        if escaped
          escaped = false
        elsif char == '\\' && in_string
          escaped = true
        elsif char == '"'
          in_string = !in_string
        elsif char == '#' && !in_string
          return line[0...index]
        end
      end
      line
    end

    private def self.split_key(key : String, source : String, number : Int32) : Array(String)
      parts = key.split('.').map(&.strip)
      if parts.empty? || parts.any?(&.empty?)
        raise Error.new("Invalid TOML key in #{source}:#{number}")
      end
      parts
    end

    private def self.parse_value(raw : String, source : String, number : Int32) : TomlScalar
      if raw.starts_with?('"')
        parse_string(raw, source, number)
      elsif raw.starts_with?('[')
        parse_string_array(raw, source, number)
      elsif raw == "true"
        true
      elsif raw == "false"
        false
      elsif raw.includes?('.') || raw.includes?('e') || raw.includes?('E')
        raw.to_f64
      else
        raw.to_i64
      end
    rescue ArgumentError
      raise Error.new("Invalid TOML value in #{source}:#{number}: #{raw}")
    end

    private def self.parse_string(raw : String, source : String, number : Int32) : String
      raise Error.new("Invalid TOML string in #{source}:#{number}") unless raw.ends_with?('"') && raw.size >= 2
      body = raw[1...-1]
      output = String.build do |io|
        escaped = false
        body.each_char do |char|
          if escaped
            case char
            when '"', '\\'
              io << char
            when 'n'
              io << '\n'
            when 't'
              io << '\t'
            else
              raise Error.new("Unsupported TOML escape \\#{char} in #{source}:#{number}")
            end
            escaped = false
          elsif char == '\\'
            escaped = true
          else
            io << char
          end
        end
        raise Error.new("Invalid trailing TOML escape in #{source}:#{number}") if escaped
      end
      output
    end

    private def self.parse_string_array(raw : String, source : String, number : Int32) : Array(String)
      raise Error.new("Invalid TOML array in #{source}:#{number}") unless raw.ends_with?(']')
      body = raw[1...-1].strip
      return [] of String if body.empty?

      values = [] of String
      token = String::Builder.new
      in_string = false
      escaped = false
      body.each_char do |char|
        if escaped
          token << '\\'
          token << char
          escaped = false
        elsif char == '\\' && in_string
          escaped = true
        elsif char == '"'
          in_string = !in_string
          token << char
        elsif char == ',' && !in_string
          values << parse_string(token.to_s.strip, source, number)
          token = String::Builder.new
        else
          token << char
        end
      end
      raise Error.new("Unterminated TOML array string in #{source}:#{number}") if in_string
      tail = token.to_s.strip
      values << parse_string(tail, source, number) unless tail.empty?
      values
    end
  end

  struct ConfigSource
    getter label : String
    getter path : String

    def initialize(@label : String, @path : String)
    end
  end

  struct ConfigSourceStatus
    getter label : String
    getter path : String
    getter exists : Bool
    getter used : Bool

    def initialize(@label : String, @path : String, @exists : Bool, @used : Bool)
    end
  end

  struct LoadedConfig
    getter config : Config
    getter sources : Array(ConfigSource)

    def initialize(@config : Config, @sources : Array(ConfigSource))
    end
  end

  class Config
    property printer_name : String?
    property printer_candidates : Array(String)
    property paper_width_mm : Float64
    property printable_width_pt : Float64
    property min_media_pt : Float64
    property max_media_height_pt : Float64
    property typst_bin : String
    property typst_mode : String
    property image_ppi : Int32
    property raster_ppi_multiplier : Int32
    property latex_engine : String
    property cups_copies : Int32
    property cups_dry_run : Bool
    property cups_paper_cut : String?
    property cups_options : Hash(String, String)

    def initialize(@printer_name : String? = nil,
                   @printer_candidates = ["EPSON_TM_m30III", "EPSON_TM_m30III__USB_"],
                   @paper_width_mm = 80.0,
                   @printable_width_pt = 204.3,
                   @min_media_pt = 72.0,
                   @max_media_height_pt = 5669.3,
                   @typst_bin = "typst",
                   @typst_mode = "pdf",
                   @image_ppi = 203,
                   @raster_ppi_multiplier = 2,
                   @latex_engine = "auto",
                   @cups_copies = 1,
                   @cups_dry_run = false,
                   @cups_paper_cut = "CutPerPage",
                   @cups_options = {
                     "Resolution"        => "203x203dpi",
                     "TmxPaperReduction" => "Off",
                   })
    end

    def self.load(cwd = Dir.current) : Config
      load_with_sources(cwd).config
    end

    def self.load_with_sources(cwd = Dir.current) : LoadedConfig
      config = new
      sources = used_sources(cwd)
      sources.each do |source|
        config.overlay_file(source.path)
      end
      config.validate!
      LoadedConfig.new(config, sources)
    end

    def self.source_statuses(cwd = Dir.current) : Array(ConfigSourceStatus)
      statuses = [] of ConfigSourceStatus
      if path = global_path
        exists = File.exists?(path)
        statuses << ConfigSourceStatus.new("global", path, exists, exists)
      end

      local = File.join(cwd, "config.toml")
      legacy_local = File.join(cwd, "bon", "config.toml")
      local_exists = File.exists?(local)
      legacy_exists = File.exists?(legacy_local)
      statuses << ConfigSourceStatus.new("local", local, local_exists, local_exists)
      statuses << ConfigSourceStatus.new("legacy local", legacy_local, legacy_exists, !local_exists && legacy_exists)
      statuses
    end

    def self.used_sources(cwd = Dir.current) : Array(ConfigSource)
      source_statuses(cwd).select(&.used).map { |status| ConfigSource.new(status.label, status.path) }
    end

    def self.validate_file!(path : String) : Nil
      config = new
      config.overlay_file(path)
      config.validate!
    end

    def self.global_path : String?
      base = ENV["XDG_CONFIG_HOME"]?
      if base && !base.empty?
        File.join(base, "bon", "config.toml")
      elsif home = ENV["HOME"]?
        File.join(home, ".config", "bon", "config.toml")
      end
    end

    def self.default_toml : String
      new.to_toml
    end

    def to_toml : String
      build_toml(comment_nil_name: true)
    end

    def to_effective_toml : String
      build_toml(comment_nil_name: false)
    end

    private def build_toml(comment_nil_name : Bool) : String
      String.build do |io|
        io << "[printer]\n"
        if name = @printer_name
          io << "name = \"#{toml_escape(name)}\"\n"
        elsif comment_nil_name
          io << "# name = \"EPSON_TM_m30III\"\n"
        else
          io << "name = \"\"\n"
        end
        io << "candidates = ["
        io << @printer_candidates.map { |candidate| "\"#{toml_escape(candidate)}\"" }.join(", ")
        io << "]\n\n"

        io << "[paper]\n"
        io << "width_mm = #{@paper_width_mm}\n"
        io << "printable_width_pt = #{@printable_width_pt}\n"
        io << "min_media_pt = #{@min_media_pt}\n"
        io << "max_media_height_pt = #{@max_media_height_pt}\n\n"

        io << "[render]\n"
        io << "typst_bin = \"#{toml_escape(@typst_bin)}\"\n"
        io << "typst_mode = \"#{toml_escape(@typst_mode)}\"\n"
        io << "image_ppi = #{@image_ppi}\n"
        io << "raster_ppi_multiplier = #{@raster_ppi_multiplier}\n"
        io << "latex_engine = \"#{toml_escape(@latex_engine)}\"\n\n"

        io << "[cups]\n"
        io << "copies = #{@cups_copies}\n"
        io << "dry_run = #{@cups_dry_run}\n"
        if paper_cut = @cups_paper_cut
          io << "paper_cut = \"#{toml_escape(paper_cut)}\"\n\n"
        else
          io << "paper_cut = \"\"\n\n"
        end

        io << "[cups.options]\n"
        @cups_options.keys.sort.each do |key|
          io << "#{key} = \"#{toml_escape(@cups_options[key])}\"\n"
        end
      end
    end

    def overlay_file(path : String) : Nil
      overlay(Toml.parse_file(path), path)
    end

    def overlay(values : Hash(String, TomlScalar), source = "config") : Nil
      values.each do |key, value|
        case key
        when "printer.name"
          name = expect_string(key, value, source)
          @printer_name = name.empty? ? nil : name
        when "printer.candidates"
          @printer_candidates = expect_string_array(key, value, source)
        when "paper.width_mm"
          @paper_width_mm = expect_number(key, value, source)
        when "paper.printable_width_pt"
          @printable_width_pt = expect_number(key, value, source)
        when "paper.min_media_pt"
          @min_media_pt = expect_number(key, value, source)
        when "paper.max_media_height_pt"
          @max_media_height_pt = expect_number(key, value, source)
        when "render.typst_bin"
          @typst_bin = expect_string(key, value, source)
        when "render.typst_mode"
          @typst_mode = expect_string(key, value, source)
        when "render.image_ppi"
          @image_ppi = expect_int(key, value, source)
        when "render.raster_ppi_multiplier"
          @raster_ppi_multiplier = expect_int(key, value, source)
        when "render.latex_engine"
          @latex_engine = expect_string(key, value, source)
        when "cups.copies"
          @cups_copies = expect_int(key, value, source)
        when "cups.dry_run"
          @cups_dry_run = expect_bool(key, value, source)
        when "cups.paper_cut"
          paper_cut = expect_string(key, value, source)
          @cups_paper_cut = paper_cut.empty? ? nil : paper_cut
        else
          if key.starts_with?("cups.options.")
            @cups_options[key[13..]] = scalar_to_string(key, value, source)
          else
            raise Error.new("Unknown config key #{key} in #{source}")
          end
        end
      end
    end

    def validate! : Nil
      raise Error.new("paper.width_mm must be positive") unless @paper_width_mm > 0
      raise Error.new("paper.printable_width_pt must be positive") unless @printable_width_pt > 0
      raise Error.new("paper.min_media_pt must be positive") unless @min_media_pt > 0
      raise Error.new("paper.max_media_height_pt must be positive") unless @max_media_height_pt > 0
      raise Error.new("render.typst_mode must be either \"pdf\" or \"raster\"") unless {"pdf", "raster"}.includes?(@typst_mode)
      raise Error.new("render.image_ppi must be positive") unless @image_ppi > 0
      raise Error.new("render.raster_ppi_multiplier must be positive") unless @raster_ppi_multiplier > 0
      raise Error.new("cups.copies must be at least 1") unless @cups_copies >= 1
      if paper_cut = @cups_paper_cut
        raise Error.new("cups.paper_cut must be CutPerPage, CutPerJob, NoCut, or empty") unless {"CutPerPage", "CutPerJob", "NoCut"}.includes?(paper_cut)
      end
    end

    def paper_width_pt : Float64
      @paper_width_mm * 72.0 / 25.4
    end

    private def expect_string(key : String, value : TomlScalar, source : String) : String
      value.as?(String) || raise Error.new("Config value #{key} in #{source} must be a string")
    end

    private def expect_string_array(key : String, value : TomlScalar, source : String) : Array(String)
      value.as?(Array(String)) || raise Error.new("Config value #{key} in #{source} must be a string array")
    end

    private def expect_bool(key : String, value : TomlScalar, source : String) : Bool
      bool = value.as?(Bool)
      bool.nil? ? raise Error.new("Config value #{key} in #{source} must be a boolean") : bool
    end

    private def expect_int(key : String, value : TomlScalar, source : String) : Int32
      int = value.as?(Int64) || raise Error.new("Config value #{key} in #{source} must be an integer")
      int.to_i32
    end

    private def expect_number(key : String, value : TomlScalar, source : String) : Float64
      case value
      when Int64
        value.to_f64
      when Float64
        value
      else
        raise Error.new("Config value #{key} in #{source} must be a number")
      end
    end

    private def scalar_to_string(key : String, value : TomlScalar, source : String) : String
      case value
      when String
        value
      when Bool
        value ? "true" : "false"
      when Int64, Float64
        value.to_s
      else
        raise Error.new("Config value #{key} in #{source} must be a string, number, or boolean")
      end
    end

    private def toml_escape(value : String) : String
      value.gsub("\\", "\\\\").gsub("\"", "\\\"")
    end
  end
end
