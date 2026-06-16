require "option_parser"
require "file_utils"

require "./config"
require "./cups"
require "./document"
require "./simulate"

module Bon
  class Cli
    VERSION = "0.1.0"

    def self.run(argv = ARGV, output_io : IO = STDOUT, error_io : IO = STDERR) : Int32
      new(argv, output_io, error_io).run
    end

    def initialize(@argv : Array(String), @output_io : IO = STDOUT, @error_io : IO = STDERR)
      @files = [] of String
      @cli_options = Hash(String, String).new
      @no_crop = false
      @show_help = false
      @show_version = false
    end

    def run : Int32
      command, argv = dispatch(@argv)
      case command
      when "print"
        run_print(argv)
      when "simulate"
        run_simulate(argv)
      when "init"
        run_init(argv)
      when "printer"
        run_printer(argv)
      when "config"
        run_config(argv)
      else
        raise Error.new("Unknown command: #{command}")
      end
    rescue ex : OptionParser::Exception | Error | File::Error | IO::Error
      @error_io.puts("error: #{ex.message}")
      2
    end

    private def dispatch(argv : Array(String)) : Tuple(String, Array(String))
      first = argv.first?
      if first == "sim"
        {"simulate", argv[1..]}
      elsif first == "print" || first == "simulate" || first == "init" || first == "printer" || first == "config"
        {first.not_nil!, argv[1..]}
      else
        {"print", argv}
      end
    end

    private def run_print(argv : Array(String)) : Int32
      reset_print_state
      if help_requested?(argv)
        @output_io.puts(build_print_parser(Config.new))
        return 0
      end
      if version_requested?(argv)
        @output_io.puts("bon #{VERSION}")
        return 0
      end

      config = Config.load
      parser = build_print_parser(config)
      parser.parse(argv)
      config.validate!

      if @show_help
        @output_io.puts(parser)
        return 0
      end

      if @show_version
        @output_io.puts("bon #{VERSION}")
        return 0
      end

      if @files.empty?
        @error_io.puts(parser)
        @error_io.puts("error: FILE is required")
        return 2
      end

      queue = Cups.discover(config)
      print_documents(@files, queue.name, config)
      0
    end

    private def reset_print_state : Nil
      @files = [] of String
      @cli_options = Hash(String, String).new
      @no_crop = false
      @show_help = false
      @show_version = false
    end

    private def build_print_parser(config : Config) : OptionParser
      OptionParser.new do |parser|
        parser.banner = <<-TEXT
          Usage: bon [print] [options] FILE...
                 bon simulate [options] [FILE...]
                 bon sim [options] [FILE...]
                 bon printer [list]
                 bon config <check|show|edit>
                 bon init [options]

          Commands:
            print      Print one or more files. This is the default command.
            simulate   Render receipt mockups for Typst and image inputs.
            sim        Alias for simulate.
            printer    List discovered CUPS printer queues.
            config     Validate, show, or edit configuration.
            init       Write a default config file.

          Print options:
          TEXT

        parser.on("-d NAME", "--printer=NAME", "CUPS printer queue") { |name| config.printer_name = name }
        parser.on("-n N", "--copies=N", "Number of copies") { |copies| config.cups_copies = parse_int(copies, "--copies") }
        parser.on("-o KEY=VALUE", "--option=KEY=VALUE", "Additional CUPS option") do |option|
          key, separator, value = option.partition("=")
          raise Error.new("CUPS option must use KEY=VALUE syntax: #{option}") if separator.empty? || key.empty?
          @cli_options[key] = value
        end
        parser.on("--paper-mm=N", "Physical paper width in millimeters") { |value| config.paper_width_mm = parse_float(value, "--paper-mm") }
        parser.on("--printable-width-pt=N", "Printable CUPS width in points") { |value| config.printable_width_pt = parse_float(value, "--printable-width-pt") }
        parser.on("--no-crop", "Do not center-crop pages wider than printable width") { @no_crop = true }
        parser.on("--dry-run", "Show external commands without sending lp jobs") { config.cups_dry_run = true }
        parser.on("--version", "Show version") { @show_version = true }
        parser.on("-h", "--help", "Show help") { @show_help = true }
        parser.unknown_args do |before_dash, after_dash|
          @files.concat(before_dash)
          @files.concat(after_dash)
        end
      end
    end

    private def run_printer(argv : Array(String)) : Int32
      show_help = false
      subcommands = [] of String
      parser = OptionParser.new do |parser|
        parser.banner = <<-TEXT
          Usage: bon printer [list]

          Commands:
            list       List discovered CUPS printer queues. This is the default printer command.

          Printer options:
          TEXT
        parser.on("-h", "--help", "Show help") { show_help = true }
        parser.unknown_args do |before_dash, after_dash|
          subcommands.concat(before_dash)
          subcommands.concat(after_dash)
        end
      end
      parser.parse(argv)

      if show_help
        @output_io.puts(parser)
        return 0
      end

      subcommand = subcommands.first?
      if subcommand.nil? || subcommand == "list"
        raise Error.new("Unexpected arguments for bon printer list: #{subcommands[1..].join(" ")}") if subcommands.size > 1
        Cups.print_list(@output_io)
        return 0
      end

      raise Error.new("Unknown printer command: #{subcommand}")
    end

    private def run_config(argv : Array(String)) : Int32
      show_help = false
      use_global = false
      subcommands = [] of String
      parser = OptionParser.new do |parser|
        parser.banner = <<-TEXT
          Usage: bon config <check|show|edit> [options]

          Commands:
            check      Validate config files and show which sources are used.
            show       Show the effective merged config, including defaults.
            edit       Open the config file in $VISUAL, $EDITOR, or vi, then validate it.

          Config options:
          TEXT
        parser.on("-g", "--global", "Edit the global bon config") { use_global = true }
        parser.on("-h", "--help", "Show help") { show_help = true }
        parser.unknown_args do |before_dash, after_dash|
          subcommands.concat(before_dash)
          subcommands.concat(after_dash)
        end
      end
      parser.parse(argv)

      if show_help
        @output_io.puts(parser)
        return 0
      end

      subcommand = subcommands.first?
      unless subcommand
        @error_io.puts(parser)
        @error_io.puts("error: CONFIG COMMAND is required")
        return 2
      end
      raise Error.new("Unexpected arguments for bon config #{subcommand}: #{subcommands[1..].join(" ")}") if subcommands.size > 1

      case subcommand
      when "check"
        raise Error.new("--global can only be used with bon config edit") if use_global
        run_config_check
      when "show"
        raise Error.new("--global can only be used with bon config edit") if use_global
        run_config_show
      when "edit"
        run_config_edit(use_global)
      else
        raise Error.new("Unknown config command: #{subcommand}")
      end
    end

    private def run_config_check : Int32
      statuses = Config.source_statuses
      Config.load_with_sources

      @output_io.puts("Config OK")
      print_config_sources(statuses)
      0
    end

    private def run_config_show : Int32
      loaded = Config.load_with_sources
      @output_io.print(loaded.config.to_effective_toml)
      0
    end

    private def run_config_edit(use_global : Bool) : Int32
      path = if use_global
               Config.global_path || raise Error.new("Could not determine global config path")
             else
               File.join(Dir.current, "config.toml")
             end

      ensure_config_file(path)
      editor = default_editor
      command = "#{editor} #{Command.shell_escape(path)}"
      status = Process.run(command, shell: true, input: STDIN, output: @output_io, error: @error_io)
      raise Error.new("Editor failed: #{editor}") unless status.success?

      if use_global
        config = Config.new
        config.overlay_file(path)
        config.validate!
      else
        Config.load_with_sources
      end
      @output_io.puts("Config OK: #{path}")
      0
    end

    private def ensure_config_file(path : String) : Nil
      return if File.exists?(path)

      parent = File.dirname(path)
      FileUtils.mkdir_p(parent) unless Dir.exists?(parent)
      File.write(path, Config.default_toml)
    end

    private def default_editor : String
      visual = ENV["VISUAL"]?
      return visual if visual && !visual.empty?

      editor = ENV["EDITOR"]?
      return editor if editor && !editor.empty?

      "vi"
    end

    private def print_config_sources(statuses : Array(ConfigSourceStatus)) : Nil
      @output_io.puts("Sources:")
      @output_io.puts("  defaults: built-in (used)")
      statuses.each do |status|
        state = if status.used
                  "used"
                elsif status.exists
                  "ignored"
                else
                  "not found"
                end
        @output_io.puts("  #{status.label}: #{status.path} (#{state})")
      end
    end

    private def run_simulate(argv : Array(String)) : Int32
      if help_requested?(argv)
        options = Simulate::Options.new
        files = [] of String
        show_help = [false]
        @output_io.puts(build_simulate_parser(options, files, show_help))
        return 0
      end

      config = Config.load
      options = Simulate::Options.new(
        paper_mm: config.paper_width_mm,
        printable_width_mm: config.printable_width_pt * 25.4 / 72.0,
        printable_width_auto: !config.explicit_printable_width_pt?,
        ppi: config.image_ppi,
        typst_bin: config.typst_bin,
        background_tint: config.simulate_background_tint,
        foreground_rgb: Simulate.parse_color(config.simulate_foreground_color),
        foreground_fade: config.simulate_foreground_fade
      )
      files = [] of String
      show_help = [false]
      parser = build_simulate_parser(options, files, show_help)
      parser.parse(argv)

      if show_help[0]
        @output_io.puts(parser)
        return 0
      end

      validate_simulate_options(options)
      sources = files.empty? ? Simulate.default_sources : files
      outputs = Simulate.render_sources(sources, options, @output_io, @error_io)
      outputs.each { |output| @output_io.puts(File.expand_path(output)) }
      0
    end

    private def build_simulate_parser(options : Simulate::Options, files : Array(String), show_help : Array(Bool)) : OptionParser
      OptionParser.new do |parser|
        parser.banner = "Usage: bon simulate|sim [options] [FILE...]"
        parser.on("-f FORMAT", "--format=FORMAT", "Output format, png or pdf") { |value| options.format = value.sub(/^\./, "") }
        parser.on("--paper-mm=N", "Simulated paper width in millimeters") do |value|
          options.paper_mm = parse_float(value, "--paper-mm")
          options.printable_width_mm = Config.default_printable_width_pt(options.paper_mm) * 25.4 / 72.0 if options.printable_width_auto
        end
        parser.on("--content-mm=N", "Printed content width in millimeters") { |value| options.content_mm = parse_float(value, "--content-mm") }
        parser.on("--ppi=N", "Typst content render PPI") { |value| options.ppi = parse_int(value, "--ppi") }
        parser.on("--mockup-ppi=N", "Final mockup image PPI") { |value| options.mockup_ppi = parse_int(value, "--mockup-ppi") }
        parser.on("--top-mm=N", "Paper shown above the printed content") { |value| options.top_mm = parse_float(value, "--top-mm") }
        parser.on("--bottom-mm=N", "Paper shown below the printed content") { |value| options.bottom_mm = parse_float(value, "--bottom-mm") }
        parser.on("--no-crop", "Do not center-crop content wider than printable width") { options.no_crop = true }
        parser.on("--background-tint=HEX", "Paper background tint as #RRGGBB") { |value| options.background_tint = value }
        parser.on("--foreground-color=HEX", "Mockup foreground color, for example #232320") { |value| options.foreground_rgb = Simulate.parse_color(value) }
        parser.on("--foreground-fade=N", "Mockup foreground opacity from 0.0 to 1.0") { |value| options.foreground_fade = parse_float(value, "--foreground-fade") }
        parser.on("--out-dir=DIR", "Directory for generated outputs") do |value|
          options.out_dir = File.expand_path(value)
        end
        parser.on("--typst-bin=PATH", "Typst executable to use") { |value| options.typst_bin = value }
        parser.on("-h", "--help", "Show help") { show_help[0] = true }
        parser.unknown_args do |before_dash, after_dash|
          files.concat(before_dash)
          files.concat(after_dash)
        end
      end
    end

    private def validate_simulate_options(options : Simulate::Options) : Nil
      raise Error.new("--format is required") if options.format.empty?
      raise Error.new("--format must not contain path separators") if options.format.includes?(File::SEPARATOR) || options.format.includes?('/') || options.format.includes?('\\')
      raise Error.new("--format must be png or pdf") unless {"png", "pdf"}.includes?(options.format)
      raise Error.new("--paper-mm, --ppi, and --mockup-ppi must be positive") unless options.paper_mm > 0 && options.ppi > 0 && options.mockup_ppi > 0
      raise Error.new("printable width must be positive") unless options.printable_width_mm > 0
      raise Error.new("printable width must not exceed --paper-mm") if options.printable_width_mm > options.paper_mm
      if content_mm = options.content_mm
        raise Error.new("--content-mm must be positive") unless content_mm > 0
        raise Error.new("--content-mm must not exceed --paper-mm") if content_mm > options.paper_mm
      end
      raise Error.new("--top-mm and --bottom-mm cannot be negative") if options.top_mm < 0 || options.bottom_mm < 0
      raise Error.new("--foreground-fade must be between 0.0 and 1.0") unless options.foreground_fade >= 0.0 && options.foreground_fade <= 1.0
      Simulate.parse_rgb(options.background_tint)
    end

    private def run_init(argv : Array(String)) : Int32
      use_global = false
      force = false
      show_help = false
      parser = OptionParser.new do |parser|
        parser.banner = "Usage: bon init [options]"
        parser.on("--global", "Write the global bon config") { use_global = true }
        parser.on("--force", "Overwrite an existing config") { force = true }
        parser.on("-h", "--help", "Show help") { show_help = true }
      end
      parser.parse(argv)

      if show_help
        @output_io.puts(parser)
        return 0
      end

      path = if use_global
               Config.global_path || raise Error.new("Could not determine global config path")
             else
               File.join(Dir.current, "config.toml")
             end
      raise Error.new("Config already exists: #{path}; pass --force to overwrite") if File.exists?(path) && !force

      parent = File.dirname(path)
      FileUtils.mkdir_p(parent) unless Dir.exists?(parent)
      File.write(path, Config.default_toml)
      @output_io.puts(path)
      0
    end

    private def print_documents(files : Array(String), printer : String, config : Config) : Nil
      # Fail fast on unsupported driver options before doing any rasterization.
      supported = Cups.driver_options(printer)
      if supported
        Cups.validate_against!(printer, config.cups_options, supported)
        Cups.validate_against!(printer, @cli_options, supported)
      end

      with_temp_dir("bon-cups-") do |temp_dir|
        files.each_with_index(1) do |source, index|
          document = Document.prepare(source, temp_dir, index, config, @no_crop, config.cups_dry_run, @output_io, @error_io)
          document.pages.each do |page|
            options = Cups.build_options(config, page.size, @cli_options)
            Cups.validate_against!(printer, options, supported) if supported
            command = Cups.lp_command(printer, config.cups_copies, options, page.path)
            Command.run(command, "CUPS printing failed for #{source}", config.cups_dry_run, false, @output_io, @error_io)
          end
        end
      end
    end

    private def with_temp_dir(prefix : String, & : String ->) : Nil
      base = Dir.tempdir
      path = ""
      100.times do
        candidate = File.join(base, "#{prefix}#{Process.pid}-#{Time.utc.to_unix_ns}-#{Random.rand(1_000_000)}")
        unless Dir.exists?(candidate) || File.exists?(candidate)
          path = candidate
          Dir.mkdir(candidate)
          break
        end
      end
      raise Error.new("Could not create temporary directory") if path.empty?

      begin
        yield path
      ensure
        FileUtils.rm_rf(path) unless path.empty?
      end
    end

    private def help_requested?(argv : Array(String)) : Bool
      argv.any? { |arg| arg == "-h" || arg == "--help" }
    end

    private def version_requested?(argv : Array(String)) : Bool
      argv.any? { |arg| arg == "--version" }
    end

    private def parse_int(value : String, option : String) : Int32
      value.to_i32
    rescue ex : ArgumentError | OverflowError
      raise Error.new("#{option} must be an integer")
    end

    private def parse_float(value : String, option : String) : Float64
      value.to_f64
    rescue ArgumentError
      raise Error.new("#{option} must be a number")
    end
  end
end
