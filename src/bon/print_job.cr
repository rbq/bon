require "file_utils"

require "./config"
require "./cups"
require "./document"

module Bon
  module PrintJob
    alias SourceResolver = Proc(String, String, Array(String))

    def self.run(files : Array(String), printer : String, config : Config, no_crop : Bool = false, extra_options : Hash(String, String) = Hash(String, String).new, output_io : IO = STDOUT, error_io : IO = STDERR, source_resolver : SourceResolver? = nil, verbose : Verbose? = nil) : Nil
      # Fail fast on unsupported driver options before doing any rasterization.
      verbose.try &.log("validating CUPS options for printer #{printer}")
      supported = Cups.driver_options(printer, verbose)
      verbose.try &.log(supported ? "printer driver option list is available" : "printer driver option list is unavailable; skipping driver-specific validation")
      if supported
        Cups.validate_against!(printer, config.cups_options, supported)
        Cups.validate_against!(printer, extra_options, supported)
      end

      with_temp_dir("bon-cups-") do |temp_dir|
        index = 0
        files.each do |source|
          verbose.try &.log("processing input #{source}")
          resolved_sources = source_resolver ? source_resolver.call(source, temp_dir) : [source]
          resolved_sources.each do |resolved_source|
            index += 1
            verbose.try &.log("preparing #{resolved_source}")
            document = Document.prepare(resolved_source, temp_dir, index, config, no_crop, config.cups_dry_run, output_io, error_io, verbose)
            document.pages.each do |page|
              options = Cups.build_options(config, page.size, extra_options)
              verbose.try &.log("built CUPS options for #{File.basename(page.path)}: #{format_options(options)}")
              Cups.validate_against!(printer, options, supported) if supported
              command = Cups.lp_command(printer, config.cups_copies, options, page.path)
              Command.run(command, "CUPS printing failed for #{source}", config.cups_dry_run, false, output_io, error_io, verbose)
            end
          end
        end
      end
    end

    private def self.format_options(options : Hash(String, String)) : String
      options.map { |key, value| "#{key}=#{value}" }.join(", ")
    end

    def self.with_temp_dir(prefix : String, & : String -> T) : T forall T
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
  end
end
