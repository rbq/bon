require "./command"
require "./config"

module Bon
  module Cups
    CONNECTION_FAILURE_TOKENS = [
      "looking for printer",
      "unable to locate",
      "offline",
      "not connected",
      "connection failed",
    ]

    THERMAL_TOKENS = [
      "tm-",
      "tm_",
      "epson_tm",
      "receipt",
      "thermal",
      "pos",
      "star",
      "bixolon",
      "citizen",
      "xprinter",
      "zebra",
    ]

    struct Queue
      getter name : String
      getter uri : String
      getter enabled : Bool
      getter status : String

      def initialize(@name : String, @uri : String, @enabled = true, @status = "")
      end

      def usable? : Bool
        return false unless @enabled
        down = @status.downcase
        !CONNECTION_FAILURE_TOKENS.any? { |token| down.includes?(token) }
      end

      def thermal? : Bool
        haystack = "#{@name} #{@uri}".downcase
        THERMAL_TOKENS.any? { |token| haystack.includes?(token) }
      end

      def usb? : Bool
        @uri.downcase.includes?("usb")
      end
    end

    def self.discover(config : Config, available_queues : Array(Queue) = queues) : Queue
      if name = config.printer_name
        queue = available_queues.find { |candidate| candidate.name == name }
        raise Error.new("Configured printer not found: #{name}") unless queue
        raise Error.new("Configured printer is not usable: #{name}") unless queue.usable?
        return queue
      end

      usable_thermal_queues(available_queues).first? || raise Error.new("No usable thermal CUPS printer found")
    end

    def self.usable_thermal_queues(available_queues : Array(Queue) = queues) : Array(Queue)
      available_queues.select { |queue| queue.usable? && queue.thermal? }.sort_by do |queue|
        {queue.usb? ? 1 : 0, queue.name}
      end
    end

    def self.valid_init_printer?(name : String?, available_queues : Array(Queue) = queues) : Bool
      return false unless name
      queue = available_queues.find { |candidate| candidate.name == name }
      !!(queue && queue.usable? && queue.thermal?)
    end

    def self.queues : Array(Queue)
      lpstat = Command.require_executable("lpstat")
      devices = Command.run_capture([lpstat, "-v"], "Could not list CUPS devices")
      statuses = Command.run_capture([lpstat, "-p"], "Could not list CUPS printers")
      parse_queues(devices, statuses)
    end

    def self.parse_queues(devices_text : String, statuses_text : String) : Array(Queue)
      devices = Hash(String, String).new
      devices_text.each_line do |line|
        if match = line.strip.match(/^device for\s+(.+?):\s+(.+)$/)
          devices[match[1]] = match[2]
        end
      end

      statuses = Hash(String, NamedTuple(enabled: Bool, status: String)).new
      statuses_text.each_line do |line|
        if match = line.strip.match(/^printer\s+(\S+)\s+(.+)$/)
          rest = match[2]
          statuses[match[1]] = {enabled: !rest.downcase.starts_with?("disabled"), status: rest}
        end
      end

      names = (devices.keys + statuses.keys).uniq.sort
      names.map do |name|
        status = statuses[name]?
        Queue.new(name, devices[name]? || "", status ? status[:enabled] : true, status ? status[:status] : "")
      end
    end

    def self.print_list(output_io : IO = STDOUT) : Nil
      queues.each do |queue|
        state = queue.usable? ? "usable" : "unusable"
        output_io.puts("#{queue.name}\t#{state}\t#{queue.uri}")
      end
    end

    def self.build_options(config : Config, pdf : PDF::PageSize, cli_options : Hash(String, String)) : Hash(String, String)
      options = Hash(String, String).new
      config.cups_options.each { |key, value| options[key] = value }
      cli_options.each { |key, value| options[key] = value }
      options["ppi"] = config.image_ppi.to_s unless options.has_key?("ppi")

      # Prevent CUPS from rescaling the already exactly-sized document. Without
      # this the generic PDF/image filters apply fit-to-page scaling, which
      # resamples the raster and softens thermal output.
      options["fit-to-page"] = "false" unless options.has_key?("fit-to-page")

      unless options.has_key?("media") || options.has_key?("PageSize") || options.has_key?("PageRegion")
        if pdf.height > config.max_media_height_pt + PDF::CROP_EPSILON_PT
          raise Error.new("Document height #{PDF.format_points(pdf.height)}pt exceeds paper.max_media_height_pt #{PDF.format_points(config.max_media_height_pt)}pt")
        end
        width = clamp(pdf.width, config.min_media_pt, config.paper_width_pt)
        height = {pdf.height, config.min_media_pt}.max
        options["media"] = "Custom.#{PDF.format_points(width)}x#{PDF.format_points(height)}"
      end

      options
    end

    def self.lp_command(printer : String, copies : Int32, options : Hash(String, String), document : String) : Array(String)
      command = [Command.require_executable("lp"), "-d", printer, "-n", copies.to_s]
      options.each { |key, value| command.concat(["-o", "#{key}=#{value}"]) }
      command << document
      command
    end

    # Standard CUPS job options that are always valid and never appear in the
    # printer's PPD/`lpoptions -l` listing.
    STANDARD_JOB_OPTIONS = [
      "media", "PageSize", "PageRegion", "ppi", "fit-to-page", "fitplot",
      "scaling", "copies", "number-up", "orientation-requested", "landscape",
      "page-ranges", "outputorder", "collate", "job-sheets", "job-priority",
      "job-hold-until", "print-quality", "print-color-mode", "Resolution",
    ]

    # Reads the driver-supported option keys and their allowed values from the
    # printer's PPD via `lpoptions -l`. Returns nil if the listing is
    # unavailable (so validation is skipped rather than blocking printing).
    def self.driver_options(printer : String) : Hash(String, Array(String))?
      lpoptions = Process.find_executable("lpoptions")
      return nil unless lpoptions
      stdout = IO::Memory.new
      stderr = IO::Memory.new
      status = Process.run(lpoptions, ["-p", printer, "-l"], output: stdout, error: stderr)
      return nil unless status.success?
      parse_driver_options(stdout.to_s)
    end

    def self.parse_driver_options(text : String) : Hash(String, Array(String))
      result = Hash(String, Array(String)).new
      text.each_line do |line|
        stripped = line.strip
        next if stripped.empty?
        key_part, separator, values_part = stripped.partition(":")
        next if separator.empty?
        key = key_part.partition("/")[0].strip
        next if key.empty?
        values = values_part.split.map { |value| value.lstrip('*') }.reject(&.empty?)
        result[key] = values
      end
      result
    end

    # Verifies that every configured option is either a standard CUPS job
    # option or a real driver option with an allowed value. Invalid options are
    # silently dropped by `lp`, so failing loudly here prevents settings that
    # never reach the printer (for example a non-existent quality option).
    def self.validate_options!(printer : String, options : Hash(String, String)) : Nil
      supported = driver_options(printer)
      return unless supported
      validate_against!(printer, options, supported)
    end

    def self.validate_against!(printer : String, options : Hash(String, String), supported : Hash(String, Array(String))) : Nil
      options.each do |key, value|
        next if STANDARD_JOB_OPTIONS.includes?(key)
        allowed = supported[key]?
        unless allowed
          raise Error.new("CUPS option #{key} is not supported by printer #{printer}; supported driver options: #{supported.keys.sort.join(", ")}")
        end
        next if allowed.empty? || value.starts_with?("Custom.")
        unless allowed.includes?(value)
          raise Error.new("CUPS option #{key}=#{value} is invalid for printer #{printer}; allowed values: #{allowed.join(", ")}")
        end
      end
    end

    private def self.clamp(value : Float64, minimum : Float64, maximum : Float64) : Float64
      {minimum, {value, maximum}.min}.max
    end
  end
end
