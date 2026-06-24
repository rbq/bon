require "./command"
require "./config"
require "./pdf"

module Bon
  module Typst
    def self.compile(source : String, output : String, root : String, config : Config, dry_run : Bool, output_io : IO = STDOUT, error_io : IO = STDERR, verbose : Verbose? = nil) : Nil
      typst = explicit_or_found(config.typst_bin)
      verbose.try &.log("compiling Typst with root #{root}")
      Command.run([
        typst,
        "compile",
        "--root",
        root,
        source,
        output,
      ], "Typst compilation failed for #{source}", dry_run, true, output_io, error_io, verbose)
    end

    def self.compile_png(source : String, output : String, root : String, ppi : Int32, config : Config, dry_run : Bool, output_io : IO = STDOUT, error_io : IO = STDERR, verbose : Verbose? = nil) : Nil
      typst = explicit_or_found(config.typst_bin)
      verbose.try &.log("compiling Typst to PNG with root #{root} at #{ppi} PPI")
      Command.run([
        typst,
        "compile",
        "--root",
        root,
        "--ppi",
        ppi.to_s,
        "-f",
        "png",
        source,
        output,
      ], "Typst PNG render failed for #{source}", dry_run, true, output_io, error_io, verbose)
    end

    def self.root_for(source : String, cwd = Dir.current) : String
      expanded = File.expand_path(source)
      current = File.expand_path(cwd)
      expanded.starts_with?(current + File::SEPARATOR) ? current : File.dirname(expanded)
    end

    private def self.explicit_or_found(name : String) : String
      if name.includes?(File::SEPARATOR)
        name
      else
        Command.require_executable(name)
      end
    end
  end
end
