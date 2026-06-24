require "option_parser"
require "file_utils"

require "./config"
require "./cups"
require "./document"
require "./print_job"
require "./simulate"
require "./web"

module Bon
  class Cli
    VERSION     = {{ read_file("shard.yml").match(/^version:\s*(\S+)\s*$/m)[1] }}
    MARGINS_TYP = {{ read_file("src/bon/assets/margins.typ") }}

    def self.run(argv = ARGV, output_io : IO = STDOUT, error_io : IO = STDERR, input_io : IO = STDIN) : Int32
      new(argv, output_io, error_io, input_io).run
    end

    def initialize(@argv : Array(String), @output_io : IO = STDOUT, @error_io : IO = STDERR, @input_io : IO = STDIN)
      @files = [] of String
      @cli_options = Hash(String, String).new
      @stdin_as = nil.as(String?)
      @no_crop = false
      @verbose = false
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
      when "web"
        run_web(argv)
      else
        raise Error.new("Unknown command: #{command}")
      end
    rescue ex : OptionParser::Exception | Error | File::Error | IO::Error
      @error_io.puts("error: #{ex.message}")
      2
    end

    private def dispatch(argv : Array(String)) : Tuple(String, Array(String))
      first = argv.first?
      if first == "sim" || first == "s"
        {"simulate", argv[1..]}
      elsif first == "p"
        {"print", argv[1..]}
      elsif first == "c"
        {"config", argv[1..]}
      elsif first == "i"
        {"init", argv[1..]}
      elsif first == "print" || first == "simulate" || first == "init" || first == "printer" || first == "config" || first == "web"
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

      loaded = Config.load_with_sources
      emit_config_warnings(loaded)
      config = loaded.config
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

      margins_command = margins_command?(@files)
      if @files.empty?
        @error_io.puts(parser)
        @error_io.puts("error: FILE is required")
        return 2
      end
      raise Error.new("Unexpected arguments for bon print margins: #{@files[1..].join(" ")}") if @files.first? == "margins" && !margins_command
      validate_stdin_sources(@files)

      queue = Cups.discover(config)
      log_verbose("selected printer #{queue.name}")
      config.apply_printer_overrides!(queue.name)
      log_verbose("applied printer-specific overrides for #{queue.name}")
      config.validate!
      if margins_command
        with_margins_typ_source { |source| print_documents([source], queue.name, config) }
      else
        print_documents(@files, queue.name, config)
      end
      0
    end

    private def reset_print_state : Nil
      @files = [] of String
      @cli_options = Hash(String, String).new
      @stdin_as = nil.as(String?)
      @no_crop = false
      @verbose = false
      @show_help = false
      @show_version = false
    end

    private def build_print_parser(config : Config) : OptionParser
      OptionParser.new do |parser|
        parser.banner = <<-TEXT
          Usage: bon [print] [options] FILE...|-
                 bon print margins [options]
                 bon simulate [options] [FILE...]
                 bon simulate margins [options]
                 bon sim|s [options] [FILE...]
                 bon printer [list]
                 bon config|c <check|show|edit>
                 bon init|i [options]
                 bon web [options]

          Commands:
            print,p    Print files, stdin document data, or stdin path lists. This is the default command.
            margins    Print the built-in 10 mm margin calibration sheet.
            simulate   Render receipt mockups for PDF, Typst, and image inputs.
            sim,s      Alias for simulate.
            printer    List discovered CUPS printer queues.
            config,c   Validate, show, or edit configuration.
            init,i     Create or refresh a config file from printer discovery.
            web        Start an HTTP upload printing server.

          Print options:
          TEXT

        parser.on("-p NAME", "--printer=NAME", "CUPS printer queue") { |name| config.printer_name = name }
        parser.on("-n N", "--copies=N", "Number of copies") { |copies| config.cups_copies = parse_int(copies, "--copies") }
        parser.on("-c KEY=VALUE", "--cups=KEY=VALUE", "Additional CUPS option") do |option|
          key, separator, value = option.partition("=")
          raise Error.new("CUPS option must use KEY=VALUE syntax: #{option}") if separator.empty? || key.empty?
          @cli_options[key] = value
        end
        parser.on("-w N", "--width=N", "Physical paper width in millimeters") { |value| config.paper_width_mm = parse_float(value, "--width") }
        parser.on("--printable-width-pt=N", "Printable CUPS width in points") { |value| config.printable_width_pt = parse_float(value, "--printable-width-pt") }
        parser.on("--raster-threshold=N", "Raster darkness cutoff from 0.0 to 1.0") { |value| config.raster_threshold = parse_float(value, "--raster-threshold") }
        parser.on("--raster-dither=MODE", "Raster dithering: none or ordered") { |value| config.raster_dither = value }
        parser.on("-f TYPE", "--stdin-format=TYPE", "Type for stdin document data: pdf, png, jpg, jpeg, typ, or tex") { |value| @stdin_as = normalize_stdin_type(value) }
        parser.on("-u", "--no-crop", "Do not center-crop pages wider than printable width") { @no_crop = true }
        parser.on("--dry-run", "Show external commands without sending lp jobs") { config.cups_dry_run = true }
        parser.on("--verbose", "Explain processing steps and decisions") { @verbose = true }
        parser.on("-v", "--version", "Show version") { @show_version = true }
        parser.on("-h", "--help", "Show help") { @show_help = true }
        parser.unknown_args do |before_dash, after_dash|
          @files.concat(before_dash)
          @files.concat(after_dash)
        end
      end
    end

    private def run_web(argv : Array(String)) : Int32
      options = Web::Options.new(token: ENV["BON_WEB_TOKEN"]?)
      show_help = false
      parser = OptionParser.new do |parser|
        parser.banner = <<-TEXT
          Usage: bon web [options]

          Starts an HTTP upload printing server. Uploads use the effective bon config
          and the same print pipeline as bon print.

          Web options:
          TEXT
        parser.on("--host=HOST", "Bind address, default #{Web::DEFAULT_HOST}") { |value| options.host = value }
        parser.on("--port=PORT", "Bind port, default #{Web::DEFAULT_PORT}") { |value| options.port = parse_int(value, "--port") }
        parser.on("--token=TOKEN", "Require upload token; overrides BON_WEB_TOKEN") { |value| options.token = value }
        parser.on("--max-upload-mb=N", "Maximum request size in MiB, default #{Web::DEFAULT_MAX_UPLOAD_MB}") do |value|
          mb = parse_int(value, "--max-upload-mb")
          raise Error.new("--max-upload-mb must be positive") unless mb > 0
          options.max_upload_bytes = mb.to_i64 * 1024 * 1024
          raise Error.new("--max-upload-mb is too large") if options.max_upload_bytes > Int32::MAX
        end
        parser.on("-h", "--help", "Show help") { show_help = true }
      end
      parser.parse(argv)

      if show_help
        @output_io.puts(parser)
        return 0
      end

      raise Error.new("--port must be between 1 and 65535") unless options.port >= 1 && options.port <= 65_535
      raise Error.new("--max-upload-mb must be positive") unless options.max_upload_bytes > 0
      raise Error.new("--max-upload-mb is too large") if options.max_upload_bytes > Int32::MAX

      Web.run(options, @output_io, @error_io)
      0
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
          Usage: bon config|c <check|show|edit> [options]

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
      loaded = Config.load_with_sources
      emit_config_warnings(loaded)

      @output_io.puts("Config OK")
      print_config_sources(statuses)
      0
    end

    private def run_config_show : Int32
      loaded = Config.load_with_sources
      emit_config_warnings(loaded)
      @output_io.print(loaded.config.to_effective_toml)
      0
    end

    private def run_config_edit(use_global : Bool) : Int32
      path = if use_global
               Config.global_path || raise Error.new("Could not determine global config path")
             else
               File.join(Dir.current, "bon.toml")
             end

      ensure_config_file(path)
      editor = default_editor
      command = "#{editor} #{Command.shell_escape(path)}"
      status = Process.run(command, shell: true, input: @input_io, output: @output_io, error: @error_io)
      raise Error.new("Editor failed: #{editor}") unless status.success?

      if use_global
        config = Config.new
        config.overlay_file(path)
        config.validate!
        emit_config_warnings(config)
      else
        loaded = Config.load_with_sources
        emit_config_warnings(loaded)
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

      loaded = Config.load_with_sources
      emit_config_warnings(loaded)
      config = loaded.config
      options = Simulate::Options.new(
        paper_mm: config.paper_width_mm,
        printable_width_mm: config.printable_width_pt * 25.4 / 72.0,
        printable_width_auto: !config.explicit_printable_width_pt?,
        ppi: config.image_ppi,
        top_mm: config.simulate_top_mm,
        bottom_mm: config.simulate_bottom_mm,
        min_top_mm: config.simulate_min_top_mm,
        min_bottom_mm: config.simulate_min_bottom_mm,
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
      margins_command = margins_command?(files)
      raise Error.new("Unexpected arguments for bon simulate margins: #{files[1..].join(" ")}") if files.first? == "margins" && !margins_command
      outputs = if margins_command
                  options.out_dir ||= Dir.current
                  with_margins_typ_source { |source| Simulate.render_sources([source], options, @output_io, @error_io) }
                else
                  sources = files.empty? ? Simulate.default_sources : files
                  Simulate.render_sources(sources, options, @output_io, @error_io)
                end
      outputs.each { |output| @output_io.puts(File.expand_path(output)) }
      0
    end

    private def build_simulate_parser(options : Simulate::Options, files : Array(String), show_help : Array(Bool)) : OptionParser
      OptionParser.new do |parser|
        parser.banner = <<-TEXT
          Usage: bon simulate|sim|s [options] [FILE...]
                 bon simulate margins [options]

          Commands:
            margins    Render the built-in 10 mm margin calibration sheet.

          Simulate options:
          TEXT
        parser.on("-f FORMAT", "--format=FORMAT", "Output format, png or pdf") { |value| options.format = value.sub(/^\./, "") }
        parser.on("-w N", "--width=N", "Simulated paper width in millimeters") do |value|
          options.paper_mm = parse_float(value, "--width")
          options.printable_width_mm = Config.default_printable_width_pt(options.paper_mm) * 25.4 / 72.0 if options.printable_width_auto
        end
        parser.on("--content-mm=N", "Printed content width in millimeters") { |value| options.content_mm = parse_float(value, "--content-mm") }
        parser.on("--ppi=N", "Typst content render PPI") { |value| options.ppi = parse_int(value, "--ppi") }
        parser.on("--mockup-ppi=N", "Final mockup image PPI") { |value| options.mockup_ppi = parse_int(value, "--mockup-ppi") }
        parser.on("--top-mm=N", "Paper shown above the printed content") { |value| options.top_mm = parse_float(value, "--top-mm") }
        parser.on("--bottom-mm=N", "Paper shown below the printed content") { |value| options.bottom_mm = parse_float(value, "--bottom-mm") }
        parser.on("-u", "--no-crop", "Do not center-crop content wider than printable width") { options.no_crop = true }
        parser.on("--background-tint=HEX", "Paper background tint as #RRGGBB") { |value| options.background_tint = value }
        parser.on("--foreground-color=HEX", "Mockup foreground color, for example #232320") { |value| options.foreground_rgb = Simulate.parse_color(value) }
        parser.on("--foreground-fade=N", "Mockup foreground opacity from 0.0 to 1.0") { |value| options.foreground_fade = parse_float(value, "--foreground-fade") }
        parser.on("--out-dir=DIR", "Directory for generated outputs") do |value|
          options.out_dir = File.expand_path(value)
        end
        parser.on("--typst-bin=PATH", "Typst executable to use") { |value| options.typst_bin = value }
        parser.on("--verbose", "Explain processing steps and decisions") { options.verbose = Verbose.new(true, @error_io) }
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
      raise Error.new("--width, --ppi, and --mockup-ppi must be positive") unless options.paper_mm > 0 && options.ppi > 0 && options.mockup_ppi > 0
      raise Error.new("printable width must be positive") unless options.printable_width_mm > 0
      raise Error.new("printable width must not exceed --width") if options.printable_width_mm > options.paper_mm
      if content_mm = options.content_mm
        raise Error.new("--content-mm must be positive") unless content_mm > 0
        raise Error.new("--content-mm must not exceed --width") if content_mm > options.paper_mm
      end
      raise Error.new("simulate margin values cannot be negative") if options.top_mm < 0 || options.bottom_mm < 0 || options.min_top_mm < 0 || options.min_bottom_mm < 0
      raise Error.new("--foreground-fade must be between 0.0 and 1.0") unless options.foreground_fade >= 0.0 && options.foreground_fade <= 1.0
      Simulate.parse_rgb(options.background_tint)
    end

    private def run_init(argv : Array(String)) : Int32
      use_global = false
      force = false
      no_interactive = false
      show_help = false
      parser = OptionParser.new do |parser|
        parser.banner = "Usage: bon init [options]"
        parser.on("--global", "Write the global bon config") { use_global = true }
        parser.on("--force", "Regenerate config from the default template") { force = true }
        parser.on("--no-interactive", "Do not prompt for printer selection") { no_interactive = true }
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
               File.join(Dir.current, "bon.toml")
             end
      existing = File.exists?(path) ? File.read(path) : nil
      configured = existing ? configured_printer_from_text(existing, path) : nil
      queues = begin
        Cups.queues
      rescue ex : Error
        @error_io.puts("warning: could not discover CUPS printers: #{ex.message}")
        [] of Cups::Queue
      end
      selected = select_init_printer(configured, queues, interactive: !no_interactive && interactive_io?)
      @error_io.puts("warning: no usable thermal CUPS printer found; leaving printer.name unset") unless selected

      parent = File.dirname(path)
      FileUtils.mkdir_p(parent) unless Dir.exists?(parent)
      if force || existing.nil?
        File.write(path, Config.default_toml(selected))
      else
        File.write(path, update_init_config_text(existing, selected))
      end
      config = Config.new
      config.overlay_file(path)
      config.validate!
      emit_config_warnings(config)
      @output_io.puts(path)
      0
    end

    private def emit_config_warnings(loaded : LoadedConfig) : Nil
      loaded.warnings.each { |warning| @error_io.puts("warning: #{warning}") }
    end

    private def emit_config_warnings(config : Config) : Nil
      config.warnings.each { |warning| @error_io.puts("warning: #{warning}") }
    end

    private def configured_printer_from_text(text : String, path : String) : String?
      config = Config.new
      config.overlay(Bon::Toml.parse(text, path), path)
      config.printer_name
    end

    private def select_init_printer(configured : String?, queues : Array(Cups::Queue), interactive : Bool) : String?
      thermal = Cups.usable_thermal_queues(queues)
      default = if configured && Cups.valid_init_printer?(configured, queues)
                  configured
                else
                  thermal.first?.try(&.name)
                end
      return default unless interactive && !thermal.empty?

      @output_io.puts("Usable thermal printers:")
      thermal.each_with_index(1) do |queue, index|
        marker = queue.name == default ? " (default)" : ""
        @output_io.puts("  #{index}. #{queue.name}#{marker}")
      end
      @output_io.puts("  0. Do not pin a printer")
      loop do
        @output_io.print("Select printer [#{default || "0"}]: ")
        answer = @input_io.gets
        raise Error.new("No printer selection received") unless answer
        stripped = answer.strip
        return default if stripped.empty?
        return nil if stripped == "0"
        if index = stripped.to_i?
          queue = thermal[index - 1]?
          return queue.name if queue
        end
        @error_io.puts("error: enter a number from 0 to #{thermal.size}")
      end
    end

    private def interactive_io? : Bool
      @input_io == STDIN && @output_io == STDOUT
    end

    private def update_init_config_text(text : String, selected : String?) : String
      lines = text.lines
      output = [] of String
      in_printer = false
      saw_printer = false
      wrote_name = false
      lines.each do |line|
        stripped = line.strip
        if stripped.starts_with?("[") && stripped.ends_with?("]")
          if in_printer && !wrote_name && selected
            output << %(name = "#{DefaultConfig.toml_escape(selected)}"\n)
            wrote_name = true
          end
          in_printer = stripped == "[printer]"
          saw_printer = true if in_printer
          output << line
          next
        end

        if in_printer
          key = stripped.partition("=")[0].strip
          if key == "name"
            unless wrote_name
              output << (selected ? %(name = "#{DefaultConfig.toml_escape(selected)}"\n) : %(# name = ""\n))
              wrote_name = true
            end
            next
          elsif key == "candidates"
            next
          end
        end
        output << line
      end
      if in_printer && !wrote_name && selected
        output << %(name = "#{DefaultConfig.toml_escape(selected)}"\n)
      elsif !saw_printer
        output << "\n" unless output.empty? || output.last.ends_with?("\n")
        output << "[printer]\n"
        output << (selected ? %(name = "#{DefaultConfig.toml_escape(selected)}"\n) : %(# name = ""\n))
      end
      output.join
    end

    private def print_documents(files : Array(String), printer : String, config : Config) : Nil
      resolver = ->(source : String, temp_dir : String) { expand_print_source(source, temp_dir) }
      PrintJob.run(files, printer, config, @no_crop, @cli_options, @output_io, @error_io, resolver, Verbose.new(@verbose, @error_io))
    end

    private def margins_command?(files : Array(String)) : Bool
      files == ["margins"]
    end

    private def with_margins_typ_source(& : String -> T) : T forall T
      PrintJob.with_temp_dir("bon-margins-") do |temp_dir|
        source = File.join(temp_dir, "margins.typ")
        File.write(source, MARGINS_TYP)
        yield source
      end
    end

    private def validate_stdin_sources(files : Array(String)) : Nil
      stdin_count = files.count { |file| file == "-" }
      raise Error.new("stdin input can only be used once") if stdin_count > 1
    end

    private def expand_print_source(source : String, temp_dir : String) : Array(String)
      return [source] unless source == "-"

      content = @input_io.gets_to_end
      raise Error.new("stdin input is empty") if content.empty?

      ext = @stdin_as || detect_stdin_type(content.to_slice)
      log_verbose("using --stdin-format=#{ext.not_nil![1..]}") if @stdin_as && ext
      unless ext
        paths = detect_stdin_paths(content)
        log_verbose("treating stdin as #{paths.size} path#{paths.size == 1 ? "" : "s"}") if paths
        return paths if paths
      end

      unless ext
        raise Error.new("Could not detect stdin input type or path list; pass --stdin-format=pdf|png|jpg|jpeg|typ|tex for document content")
      end

      path = File.join(temp_dir, "stdin#{ext}")
      log_verbose("materializing stdin document data as #{path}")
      File.write(path, content)
      [path]
    end

    private def detect_stdin_paths(content : String) : Array(String)?
      paths = content.lines.map(&.strip).reject(&.empty?)
      return nil if paths.empty?
      return nil unless paths.all? { |path| File.exists?(path) }

      paths
    end

    private def detect_stdin_type(bytes : Bytes) : String?
      return ".pdf" if starts_with?(bytes, Bytes[0x25, 0x50, 0x44, 0x46, 0x2d])
      return ".png" if starts_with?(bytes, Bytes[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
      return ".jpg" if starts_with?(bytes, Bytes[0xff, 0xd8])

      nil
    end

    private def starts_with?(bytes : Bytes, prefix : Bytes) : Bool
      bytes.size >= prefix.size && bytes[0, prefix.size] == prefix
    end

    private def normalize_stdin_type(value : String) : String
      normalized = value.downcase.sub(/^\./, "")
      ext = ".#{normalized}"
      return ext if Document::SUPPORTED_SUFFIXES.includes?(ext)

      raise Error.new("--stdin-format must be one of: pdf, png, jpg, jpeg, typ, tex")
    end

    private def log_verbose(message : String) : Nil
      Verbose.new(@verbose, @error_io).log(message)
    end

    private def help_requested?(argv : Array(String)) : Bool
      argv.any? { |arg| arg == "-h" || arg == "--help" }
    end

    private def version_requested?(argv : Array(String)) : Bool
      argv.any? { |arg| arg == "-v" || arg == "--version" }
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
