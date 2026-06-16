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
      if first == "print" || first == "simulate" || first == "init" || first == "printer" || first == "config"
        {first.not_nil!, argv[1..]}
      else
        {"print", argv}
      end
    end

    private def run_print(argv : Array(String)) : Int32
      reset_print_state
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
                 bon printer [list]
                 bon config <check|show|edit>

          Commands:
            print      Print one or more files. This is the default command.
            printer    List discovered CUPS printer queues.
            config     Validate, show, or edit configuration.

          Print options:
          TEXT

        parser.on("-d NAME", "--printer=NAME", "CUPS printer queue") { |name| config.printer_name = name }
        parser.on("-n N", "--copies=N", "Number of copies") { |copies| config.cups_copies = copies.to_i }
        parser.on("-o KEY=VALUE", "--option=KEY=VALUE", "Additional CUPS option") do |option|
          key, separator, value = option.partition("=")
          raise Error.new("CUPS option must use KEY=VALUE syntax: #{option}") if separator.empty? || key.empty?
          @cli_options[key] = value
        end
        parser.on("--paper-mm=N", "Physical paper width in millimeters") { |value| config.paper_width_mm = value.to_f64 }
        parser.on("--printable-width-pt=N", "Printable CUPS width in points") { |value| config.printable_width_pt = value.to_f64 }
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
      statuses.each do |status|
        Config.validate_file!(status.path) if status.used
      end
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

      Config.validate_file!(path)
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
      config = Config.load
      options = Simulate::Options.new(
        paper_mm: config.paper_width_mm,
        ppi: config.image_ppi,
        typst_bin: config.typst_bin
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
        parser.banner = "Usage: bon simulate [options] [FILE...]"
        parser.on("-f FORMAT", "--format=FORMAT", "Output format, for example png or pdf") { |value| options.format = value.sub(/^\./, "") }
        parser.on("--paper-mm=N", "Simulated paper width in millimeters") { |value| options.paper_mm = value.to_f64 }
        parser.on("--content-mm=N", "Printed content width in millimeters") { |value| options.content_mm = value.to_f64 }
        parser.on("--ppi=N", "Typst content render PPI") { |value| options.ppi = value.to_i }
        parser.on("--mockup-ppi=N", "Final mockup image PPI") { |value| options.mockup_ppi = value.to_i }
        parser.on("--top-mm=N", "Paper shown above the printed content") { |value| options.top_mm = value.to_f64 }
        parser.on("--bottom-mm=N", "Paper shown below the printed content") { |value| options.bottom_mm = value.to_f64 }
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
      raise Error.new("--paper-mm, --ppi, and --mockup-ppi must be positive") unless options.paper_mm > 0 && options.ppi > 0 && options.mockup_ppi > 0
      if content_mm = options.content_mm
        raise Error.new("--content-mm must be positive") unless content_mm > 0
      end
      raise Error.new("--top-mm and --bottom-mm cannot be negative") if options.top_mm < 0 || options.bottom_mm < 0
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
          options = Cups.build_options(config, document.size, @cli_options)
          Cups.validate_against!(printer, options, supported) if supported
          command = Cups.lp_command(printer, config.cups_copies, options, document.path)
          Command.run(command, "CUPS printing failed for #{source}", config.cups_dry_run, false, @output_io, @error_io)
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

    private def display_path(path : String) : String
      expanded = File.expand_path(path)
      cwd = File.expand_path(Dir.current)
      prefix = cwd + File::SEPARATOR
      expanded.starts_with?(prefix) ? expanded[prefix.size..] : expanded
    end
  end
end
