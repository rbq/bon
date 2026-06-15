require "./command"
require "./config"

module Bon
  module Latex
    ENGINES = ["latexmk", "tectonic", "pdflatex"]

    def self.compile(source : String, output : String, temp_dir : String, config : Config, dry_run : Bool, output_io : IO = STDOUT, error_io : IO = STDERR) : Nil
      engines = config.latex_engine == "auto" ? ENGINES : [config.latex_engine]
      failures = [] of String

      engines.each do |engine|
        executable = Process.find_executable(engine)
        unless executable
          failures << "#{engine}: not found"
          next
        end

        command = command_for(engine, executable, source, temp_dir)
        output_io.puts(Command.shell_join(command)) if dry_run
        success = Command.try_run(command, output_io, error_io)
        produced = File.join(temp_dir, "#{File.basename(source, File.extname(source))}.pdf")
        if success && File.exists?(produced)
          File.copy(produced, output)
          return
        end
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
