require "./command"
require "./config"

module Bon
  module Latex
    ENGINES = ["latexmk", "tectonic", "pdflatex"]

    def self.compile(source : String, output : String, temp_dir : String, config : Config, dry_run : Bool, output_io : IO = STDOUT, error_io : IO = STDERR, verbose : Verbose? = nil) : Nil
      engines = config.latex_engine == "auto" ? ENGINES : [config.latex_engine]
      failures = [] of String
      verbose.try &.log("trying LaTeX engine#{engines.size == 1 ? "" : "s"}: #{engines.join(", ")}")

      engines.each do |engine|
        executable = Process.find_executable(engine)
        unless executable
          verbose.try &.log("skipping LaTeX engine #{engine}: executable not found")
          failures << "#{engine}: not found"
          next
        end

        command = command_for(engine, executable, source, temp_dir)
        verbose.try &.log("trying LaTeX engine #{engine}")
        verbose.try &.log("running #{Command.shell_join(command)}")
        output_io.puts(Command.shell_join(command)) if dry_run
        success = Command.try_run(command, output_io, error_io)
        produced = File.join(temp_dir, "#{File.basename(source, File.extname(source))}.pdf")
        if success && File.exists?(produced)
          verbose.try &.log("LaTeX engine #{engine} produced #{produced}")
          File.copy(produced, output)
          return
        end
        verbose.try &.log("LaTeX engine #{engine} did not produce a PDF")
        failures << "#{engine}: failed"
      end

      raise Error.new("LaTeX conversion failed for #{source} (#{failures.join("; ")})")
    end

    private def self.command_for(engine : String, executable : String, source : String, temp_dir : String) : Array(String)
      case engine
      when "latexmk"
        [executable, "-pdf", "-interaction=nonstopmode", "-halt-on-error", "-outdir=#{temp_dir}", source]
      when "tectonic"
        [executable, "--outdir", temp_dir, source]
      when "pdflatex"
        [executable, "-interaction=nonstopmode", "-halt-on-error", "-output-directory", temp_dir, source]
      else
        [executable, source]
      end
    end
  end
end
