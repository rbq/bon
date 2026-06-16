require "file_utils"
require "spec"

require "../src/bon/cli"

describe Bon::Cli do
  it "documents print and printer commands in root help" do
    stdout = IO::Memory.new
    stderr = IO::Memory.new

    status = Bon::Cli.run(["--help"], stdout, stderr)

    status.should eq(0)
    stderr.to_s.should eq("")
    help = stdout.to_s
    help.should contain("Usage: bon [print] [options] FILE...")
    help.should contain("bon printer [list]")
    help.should contain("bon config <check|show>")
    help.should contain("print      Print one or more files")
    help.should contain("printer    List discovered CUPS printer queues")
    help.should contain("config     Validate or show the effective configuration")
  end

  it "documents printer subcommands in printer help" do
    stdout = IO::Memory.new
    stderr = IO::Memory.new

    status = Bon::Cli.run(["printer", "--help"], stdout, stderr)

    status.should eq(0)
    stderr.to_s.should eq("")
    help = stdout.to_s
    help.should contain("Usage: bon printer [list]")
    help.should contain("list       List discovered CUPS printer queues")
  end

  it "documents config subcommands in config help" do
    stdout = IO::Memory.new
    stderr = IO::Memory.new

    status = Bon::Cli.run(["config", "--help"], stdout, stderr)

    status.should eq(0)
    stderr.to_s.should eq("")
    help = stdout.to_s
    help.should contain("Usage: bon config <check|show>")
    help.should contain("check      Validate config files")
    help.should contain("show       Show the effective merged config")
  end

  it "checks config files and reports source usage" do
    with_cli_temp_dir do |dir|
      xdg_config = File.join(dir, "xdg")
      global_config = File.join(xdg_config, "bon", "config.toml")
      local_config = File.join(dir, "config.toml")
      FileUtils.mkdir_p(File.dirname(global_config))
      File.write(global_config, "[paper]\nwidth_mm = 58.0\n")
      File.write(local_config, "[cups]\ncopies = 2\n")
      stdout = IO::Memory.new
      stderr = IO::Memory.new

      with_cli_env({"XDG_CONFIG_HOME" => xdg_config}) do
        Dir.cd(dir) do
          current_local = File.join(Dir.current, "config.toml")
          current_legacy = File.join(Dir.current, "bon", "config.toml")
          status = Bon::Cli.run(["config", "check"], stdout, stderr)

          status.should eq(0)
          stderr.to_s.should eq("")
          output = stdout.to_s
          output.should contain("Config OK")
          output.should contain("defaults: built-in (used)")
          output.should contain("global: #{global_config} (used)")
          output.should contain("local: #{current_local} (used)")
          output.should contain("legacy local: #{current_legacy} (not found)")
        end
      end
    end
  end

  it "shows the effective merged config including defaults" do
    with_cli_temp_dir do |dir|
      xdg_config = File.join(dir, "xdg")
      local_config = File.join(dir, "config.toml")
      File.write(local_config, "[paper]\nwidth_mm = 58.0\n")
      stdout = IO::Memory.new
      stderr = IO::Memory.new

      with_cli_env({"XDG_CONFIG_HOME" => xdg_config}) do
        Dir.cd(dir) do
          status = Bon::Cli.run(["config", "show"], stdout, stderr)

          status.should eq(0)
          stderr.to_s.should eq("")
          output = stdout.to_s
          output.should contain("[printer]")
          output.should contain("name = \"\"")
          output.should contain("candidates = [\"EPSON_TM_m30III\", \"EPSON_TM_m30III__USB_\"]")
          output.should contain("width_mm = 58.0")
          output.should contain("printable_width_pt = 204.3")
          output.should contain("[cups.options]")
        end
      end
    end
  end

  it "fails config check when a used config file is invalid" do
    with_cli_temp_dir do |dir|
      xdg_config = File.join(dir, "xdg")
      File.write(File.join(dir, "config.toml"), "[paper]\nwidth_mm = -1\n")
      stdout = IO::Memory.new
      stderr = IO::Memory.new

      with_cli_env({"XDG_CONFIG_HOME" => xdg_config}) do
        Dir.cd(dir) do
          status = Bon::Cli.run(["config", "check"], stdout, stderr)

          status.should eq(2)
          stdout.to_s.should eq("")
          stderr.to_s.should contain("error: paper.width_mm must be positive")
        end
      end
    end
  end

  it "lists printers with bon printer" do
    with_cli_temp_dir do |dir|
      install_fake_lpstat(dir)
      stdout = IO::Memory.new
      stderr = IO::Memory.new

      with_cli_env({"PATH" => "#{dir}:#{ENV["PATH"]}", "XDG_CONFIG_HOME" => File.join(dir, "xdg")}) do
        status = Bon::Cli.run(["printer"], stdout, stderr)

        status.should eq(0)
        stderr.to_s.should eq("")
        stdout.to_s.should contain("EPSON_TM_m30III\tusable\tdnssd://EPSON%20TM-m30III._ipps._tcp.local/")
      end
    end
  end

  it "lists printers with bon printer list" do
    with_cli_temp_dir do |dir|
      install_fake_lpstat(dir)
      stdout = IO::Memory.new
      stderr = IO::Memory.new

      with_cli_env({"PATH" => "#{dir}:#{ENV["PATH"]}", "XDG_CONFIG_HOME" => File.join(dir, "xdg")}) do
        status = Bon::Cli.run(["printer", "list"], stdout, stderr)

        status.should eq(0)
        stderr.to_s.should eq("")
        stdout.to_s.should contain("EPSON_TM_m30III\tusable\tdnssd://EPSON%20TM-m30III._ipps._tcp.local/")
      end
    end
  end

  it "dry-runs Typst printing through a PDF-first cropped CUPS job" do
    with_cli_temp_dir do |dir|
      source = File.join(dir, "receipt.typ")
      File.write(source, "#set page(width: 80mm, height: 300pt)\nHello\n")
      install_fake_lpstat(dir)
      install_fake_print_tools(dir)
      stdout = IO::Memory.new
      stderr = IO::Memory.new

      with_cli_env({"PATH" => "#{dir}:#{ENV["PATH"]}", "XDG_CONFIG_HOME" => File.join(dir, "xdg")}) do
        Dir.cd(dir) do
          status = Bon::Cli.run(["--dry-run", source], stdout, stderr)

          status.should eq(0)
          stderr.to_s.should eq("")
          output = stdout.to_s
          output.should contain("typst compile --root")
          output.should_not contain("--ppi")
          output.should_not contain("-f png")
          output.should contain("gs -q -dNOPAUSE -dBATCH -sDEVICE=pdfwrite")
          output.should contain("-dDEVICEWIDTHPOINTS=204.3")
          output.should contain("lp -d EPSON_TM_m30III -n 1")
          output.should contain("-o media=Custom.204.3x300")
          output.should contain("-o Resolution=203x203dpi")
          output.should contain("-o TmxPaperCut=CutPerJob")
          output.should contain("-o TmxPaperReduction=Off")
          output.should contain("001-receipt-print.pdf")
          output.should_not contain("001-receipt-print.png")
        end
      end
    end
  end

  it "dry-runs LaTeX printing through a PDF-first cropped CUPS job" do
    with_cli_temp_dir do |dir|
      source = File.join(dir, "receipt.tex")
      File.write(source, "\\documentclass{article}\\begin{document}Hello\\end{document}\n")
      File.write(File.join(dir, "config.toml"), "[render]\nlatex_engine = \"pdflatex\"\n")
      install_fake_lpstat(dir)
      install_fake_print_tools(dir)
      stdout = IO::Memory.new
      stderr = IO::Memory.new

      with_cli_env({"PATH" => "#{dir}:#{ENV["PATH"]}", "XDG_CONFIG_HOME" => File.join(dir, "xdg")}) do
        Dir.cd(dir) do
          status = Bon::Cli.run(["--dry-run", source], stdout, stderr)

          status.should eq(0)
          stderr.to_s.should eq("")
          output = stdout.to_s
          output.should contain("pdflatex -interaction=nonstopmode")
          output.should contain("gs -q -dNOPAUSE -dBATCH -sDEVICE=pdfwrite")
          output.should contain("-dDEVICEWIDTHPOINTS=204.3")
          output.should contain("lp -d EPSON_TM_m30III -n 1")
          output.should contain("-o media=Custom.204.3x300")
          output.should contain("-o Resolution=203x203dpi")
          output.should contain("001-receipt-print.pdf")
          output.should_not contain("001-receipt-print.png")
          output.should_not contain("pngmono")
          output.should_not contain("pnggray")
        end
      end
    end
  end

  it "rejects unknown printer subcommands" do
    stdout = IO::Memory.new
    stderr = IO::Memory.new

    status = Bon::Cli.run(["printer", "delete"], stdout, stderr)

    status.should eq(2)
    stdout.to_s.should eq("")
    stderr.to_s.should contain("error: Unknown printer command: delete")
  end
end

private def install_fake_print_tools(dir : String) : Nil
  File.write(File.join(dir, "lp"), <<-SH)
    #!/bin/sh
    exit 0
    SH
  File.chmod(File.join(dir, "lp"), 0o755)

  File.write(File.join(dir, "lpoptions"), <<-SH)
    #!/bin/sh
    printf '%s\n' 'PageSize/Media Size: *RP80x200 RP80x2000 Custom.WIDTHxHEIGHT'
    printf '%s\n' 'Resolution/Resolution: *203x203dpi'
    printf '%s\n' 'TmxPaperReduction/Paper Reduction: *Off Top Bottom Both'
    printf '%s\n' 'TmxPaperCut/Paper Cut: NoCut *CutPerJob CutPerPage'
    SH
  File.chmod(File.join(dir, "lpoptions"), 0o755)

  File.write(File.join(dir, "typst"), <<-SH)
    #!/bin/sh
    output=""
    for arg do
      output="$arg"
    done
    cat > "$output" <<'PDF'
    %PDF-1.7
    1 0 obj <</MediaBox [0 0 226.772 300]>> endobj
    PDF
    SH
  File.chmod(File.join(dir, "typst"), 0o755)

  File.write(File.join(dir, "pdflatex"), <<-SH)
    #!/bin/sh
    outdir="."
    source=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -output-directory)
          shift
          outdir="$1"
          ;;
        *)
          source="$1"
          ;;
      esac
      shift
    done
    basename="${source##*/}"
    basename="${basename%.*}"
    cat > "$outdir/$basename.pdf" <<'PDF'
    %PDF-1.7
    1 0 obj <</MediaBox [0 0 226.772 300]>> endobj
    PDF
    SH
  File.chmod(File.join(dir, "pdflatex"), 0o755)

  File.write(File.join(dir, "gs"), <<-SH)
    #!/bin/sh
    output=""
    for arg do
      case "$arg" in
        -sOutputFile=*) output="${arg#-sOutputFile=}" ;;
      esac
    done
    cat > "$output" <<'PDF'
    %PDF-1.7
    1 0 obj <</MediaBox [0 0 204.3 300]>> endobj
    PDF
    SH
  File.chmod(File.join(dir, "gs"), 0o755)
end

private def install_fake_lpstat(dir : String) : Nil
  path = File.join(dir, "lpstat")
  File.write(path, <<-SH)
    #!/bin/sh
    case "$1" in
      -v)
        printf '%s\n' 'device for EPSON_TM_m30III: dnssd://EPSON%20TM-m30III._ipps._tcp.local/'
        printf '%s\n' 'device for EPSON_TM_m30III__USB_: usb://EPSON/TM-m30III?serial=123'
        ;;
      -p)
        printf '%s\n' 'printer EPSON_TM_m30III is idle. enabled since today'
        printf '%s\n' 'printer EPSON_TM_m30III__USB_ is idle. enabled since today'
        ;;
      *)
        exit 2
        ;;
    esac
    SH
  File.chmod(path, 0o755)
end

private def with_cli_temp_dir(& : String ->) : Nil
  dir = File.join(Dir.tempdir, "bon-cli-spec-#{Process.pid}-#{Time.utc.to_unix_ns}-#{Random.rand(1_000_000)}")
  Dir.mkdir(dir)
  begin
    yield dir
  ensure
    FileUtils.rm_rf(dir)
  end
end

private def with_cli_env(values : Hash(String, String), & : ->) : Nil
  previous = values.keys.to_h { |key| {key, ENV[key]?} }
  values.each { |key, value| ENV[key] = value }
  begin
    yield
  ensure
    previous.each do |key, value|
      if value
        ENV[key] = value
      else
        ENV.delete(key)
      end
    end
  end
end
