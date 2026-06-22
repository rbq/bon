require "file_utils"
require "spec"
require "yaml"

require "../src/bon/cli"

describe Bon::Cli do
  it "documents root commands in root help" do
    stdout = IO::Memory.new
    stderr = IO::Memory.new

    status = Bon::Cli.run(["--help"], stdout, stderr)

    status.should eq(0)
    stderr.to_s.should eq("")
    help = stdout.to_s
    help.should contain("Usage: bon [print] [options] FILE...")
    help.should contain("bon print margins [options]")
    help.should contain("bon simulate [options] [FILE...]")
    help.should contain("bon simulate margins [options]")
    help.should contain("bon sim|s [options] [FILE...]")
    help.should contain("bon printer [list]")
    help.should contain("bon config|c <check|show|edit>")
    help.should contain("bon init|i [options]")
    help.should contain("print,p    Print files, stdin document data, or stdin path lists")
    help.should contain("margins    Print the built-in 10 mm margin calibration sheet")
    help.should contain("simulate   Render receipt mockups")
    help.should contain("sim,s      Alias for simulate")
    help.should contain("printer    List discovered CUPS printer queues")
    help.should contain("config,c   Validate, show, or edit configuration")
    help.should contain("init,i     Create or refresh a config file")
    help.should contain("--raster-threshold=N")
    help.should contain("--raster-dither=MODE")
    help.should contain("-p NAME, --printer=NAME")
    help.should contain("-c KEY=VALUE, --cups=KEY=VALUE")
    help.should contain("-w N, --width=N")
    help.should contain("-f TYPE, --stdin-format=TYPE")
    help.should contain("-u, --no-crop")
  end

  it "documents the simulate alias in simulate help" do
    stdout = IO::Memory.new
    stderr = IO::Memory.new

    status = Bon::Cli.run(["sim", "--help"], stdout, stderr)

    status.should eq(0)
    stderr.to_s.should eq("")
    help = stdout.to_s
    help.should contain("Usage: bon simulate|sim|s [options] [FILE...]")
    help.should contain("bon simulate margins [options]")
    help.should contain("margins    Render the built-in 10 mm margin calibration sheet")
    help.should contain("-w N, --width=N")
    help.should contain("-u, --no-crop")
    help.should contain("--background-tint=HEX")
  end

  it "shows root help and version without loading invalid local config" do
    with_cli_temp_dir do |dir|
      File.write(File.join(dir, "bon.toml"), "[paper]\nwidth_mm = -1\n")

      Dir.cd(dir) do
        stdout = IO::Memory.new
        stderr = IO::Memory.new
        Bon::Cli.run(["--help"], stdout, stderr).should eq(0)
        stderr.to_s.should eq("")
        stdout.to_s.should contain("Usage: bon [print] [options] FILE...")

        stdout = IO::Memory.new
        stderr = IO::Memory.new
        Bon::Cli.run(["--version"], stdout, stderr).should eq(0)
        stderr.to_s.should eq("")
        stdout.to_s.should eq("bon #{YAML.parse(File.read(File.join(__DIR__, "..", "shard.yml")))["version"].as_s}\n")

        stdout = IO::Memory.new
        stderr = IO::Memory.new
        Bon::Cli.run(["-v"], stdout, stderr).should eq(0)
        stderr.to_s.should eq("")
        stdout.to_s.should eq("bon #{YAML.parse(File.read(File.join(__DIR__, "..", "shard.yml")))["version"].as_s}\n")
      end
    end
  end

  it "shows simulate help without loading invalid local config" do
    with_cli_temp_dir do |dir|
      File.write(File.join(dir, "bon.toml"), "[paper]\nwidth_mm = -1\n")

      Dir.cd(dir) do
        stdout = IO::Memory.new
        stderr = IO::Memory.new
        Bon::Cli.run(["sim", "--help"], stdout, stderr).should eq(0)
        stderr.to_s.should eq("")
        stdout.to_s.should contain("Usage: bon simulate|sim|s [options] [FILE...]")
      end
    end
  end

  it "reports invalid numeric options as CLI errors" do
    stdout = IO::Memory.new
    stderr = IO::Memory.new

    Bon::Cli.run(["--copies", "nope"], stdout, stderr).should eq(2)

    stdout.to_s.should eq("")
    stderr.to_s.should contain("error: --copies must be an integer")
  end

  it "rejects unsupported or unsafe simulate formats" do
    stdout = IO::Memory.new
    stderr = IO::Memory.new

    Bon::Cli.run(["sim", "--format", "svg"], stdout, stderr).should eq(2)
    stderr.to_s.should contain("error: --format must be png or pdf")

    stdout = IO::Memory.new
    stderr = IO::Memory.new
    Bon::Cli.run(["sim", "--format", "../x"], stdout, stderr).should eq(2)
    stderr.to_s.should contain("error: --format must not contain path separators")
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
    help.should contain("Usage: bon config|c <check|show|edit> [options]")
    help.should contain("check      Validate config files")
    help.should contain("show       Show the effective merged config")
    help.should contain("edit       Open the config file")
    help.should contain("-g, --global")
  end

  it "edits the local config and validates it after the editor exits" do
    with_cli_temp_dir do |dir|
      install_fake_editor(dir, "printf '%s\n' '[cups]' 'copies = 3' >> \"$1\"")
      stdout = IO::Memory.new
      stderr = IO::Memory.new

      with_cli_env({"PATH" => "#{dir}:#{ENV["PATH"]}", "EDITOR" => "bon-test-editor", "VISUAL" => "", "XDG_CONFIG_HOME" => File.join(dir, "xdg")}) do
        Dir.cd(dir) do
          path = File.join(Dir.current, "bon.toml")
          status = Bon::Cli.run(["c", "edit"], stdout, stderr)

          status.should eq(0)
          stderr.to_s.should eq("")
          stdout.to_s.should contain("Config OK: #{path}")
          File.exists?(path).should be_true
          File.read(path).should contain("copies = 3")
        end
      end
    end
  end

  it "edits the global config with --global and -g" do
    ["--global", "-g"].each do |flag|
      with_cli_temp_dir do |dir|
        install_fake_editor(dir, "printf '%s\n' '[paper]' 'width_mm = 58.0' >> \"$1\"")
        xdg_config = File.join(dir, "xdg")
        global_config = File.join(xdg_config, "bon.toml")
        stdout = IO::Memory.new
        stderr = IO::Memory.new

        with_cli_env({"PATH" => "#{dir}:#{ENV["PATH"]}", "EDITOR" => "bon-test-editor", "VISUAL" => "", "XDG_CONFIG_HOME" => xdg_config}) do
          Dir.cd(dir) do
            status = Bon::Cli.run(["config", "edit", flag], stdout, stderr)

            status.should eq(0)
            stderr.to_s.should eq("")
            stdout.to_s.should contain("Config OK: #{global_config}")
            File.exists?(global_config).should be_true
            File.read(global_config).should contain("width_mm = 58.0")
            File.exists?(File.join(dir, "bon.toml")).should be_false
          end
        end
      end
    end
  end

  it "fails config edit when the edited config is invalid" do
    with_cli_temp_dir do |dir|
      install_fake_editor(dir, "printf '%s\n' '[paper]' 'width_mm = -1' >> \"$1\"")
      stdout = IO::Memory.new
      stderr = IO::Memory.new

      with_cli_env({"PATH" => "#{dir}:#{ENV["PATH"]}", "EDITOR" => "bon-test-editor", "VISUAL" => "", "XDG_CONFIG_HOME" => File.join(dir, "xdg")}) do
        Dir.cd(dir) do
          status = Bon::Cli.run(["config", "edit"], stdout, stderr)

          status.should eq(2)
          stdout.to_s.should eq("")
          stderr.to_s.should contain("error: paper.width_mm must be positive")
        end
      end
    end
  end

  it "initializes config with the i alias" do
    with_cli_temp_dir do |dir|
      stdout = IO::Memory.new
      stderr = IO::Memory.new

      with_cli_env({"PATH" => dir, "XDG_CONFIG_HOME" => File.join(dir, "xdg")}) do
        Dir.cd(dir) do
          path = File.join(Dir.current, "bon.toml")
          status = Bon::Cli.run(["i", "--no-interactive"], stdout, stderr)

          status.should eq(0)
          stdout.to_s.should eq("#{path}\n")
          stderr.to_s.should contain("warning: could not discover CUPS printers")
          File.exists?(path).should be_true
        end
      end
    end
  end

  it "checks config files and reports source usage" do
    with_cli_temp_dir do |dir|
      xdg_config = File.join(dir, "xdg")
      global_config = File.join(xdg_config, "bon.toml")
      local_config = File.join(dir, "bon.toml")
      FileUtils.mkdir_p(File.dirname(global_config))
      File.write(global_config, "[paper]\nwidth_mm = 58.0\n")
      File.write(local_config, "[cups]\ncopies = 2\n")
      stdout = IO::Memory.new
      stderr = IO::Memory.new

      with_cli_env({"XDG_CONFIG_HOME" => xdg_config}) do
        Dir.cd(dir) do
          current_local = File.join(Dir.current, "bon.toml")
          status = Bon::Cli.run(["config", "check"], stdout, stderr)

          status.should eq(0)
          stderr.to_s.should eq("")
          output = stdout.to_s
          output.should contain("Config OK")
          output.should contain("defaults: built-in (used)")
          output.should contain("global: #{global_config} (used)")
          output.should contain("local: #{current_local} (used)")
          output.should_not contain("legacy local:")
        end
      end
    end
  end

  it "shows the effective merged config including defaults" do
    with_cli_temp_dir do |dir|
      xdg_config = File.join(dir, "xdg")
      local_config = File.join(dir, "bon.toml")
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
          output.should_not contain("candidates =")
          output.should contain("width_mm = 58.0")
          output.should contain("printable_width_pt = 136.197")
          output.should contain("[simulate]")
          output.should contain("background_tint = \"#f5f1e0\"")
          output.should contain("[cups.options]")
        end
      end
    end
  end

  it "fails config check when a used config file is invalid" do
    with_cli_temp_dir do |dir|
      xdg_config = File.join(dir, "xdg")
      File.write(File.join(dir, "bon.toml"), "[paper]\nwidth_mm = -1\n")
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

  it "supports the p command alias and renamed print options" do
    with_cli_temp_dir do |dir|
      source = File.join(dir, "receipt.pdf")
      File.write(source, "%PDF-1.7\n1 0 obj <</MediaBox [0 0 100 120]>> endobj\n")
      install_fake_lpstat(dir)
      install_fake_print_tools(dir)
      stdout = IO::Memory.new
      stderr = IO::Memory.new

      with_cli_env({"PATH" => "#{dir}:#{ENV["PATH"]}", "XDG_CONFIG_HOME" => File.join(dir, "xdg")}) do
        status = Bon::Cli.run(["p", "--dry-run", "-p", "EPSON_TM_m30III", "-c", "fit-to-page=true", "-w", "58", "-u", source], stdout, stderr)

        status.should eq(0)
        stderr.to_s.should eq("")
        output = stdout.to_s
        output.should contain("lp -d EPSON_TM_m30III -n 1")
        output.should contain("-o fit-to-page=true")
        output.should contain("-o media=Custom.100x120")
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
          output.should contain("-dDEVICEWIDTHPOINTS=204.296")
          output.should contain("lp -d EPSON_TM_m30III -n 1")
          output.should contain("-o media=Custom.204.296x300")
          output.should contain("-o Resolution=203x203dpi")
          output.should contain("-o TmxPaperCut=CutPerPage")
          output.should contain("-o TmxPaperReduction=Top")
          output.should contain("001-receipt-print.pdf")
          output.should_not contain("001-receipt-print.png")
        end
      end
    end
  end

  it "dry-runs the built-in print margin calibration sheet" do
    with_cli_temp_dir do |dir|
      install_fake_lpstat(dir)
      install_fake_print_tools(dir)
      stdout = IO::Memory.new
      stderr = IO::Memory.new

      with_cli_env({"PATH" => "#{dir}:#{ENV["PATH"]}", "XDG_CONFIG_HOME" => File.join(dir, "xdg")}) do
        Dir.cd(dir) do
          status = Bon::Cli.run(["print", "margins", "--dry-run"], stdout, stderr)

          status.should eq(0)
          stderr.to_s.should eq("")
          output = stdout.to_s
          output.should contain("typst compile --root")
          output.should contain("margins.typ")
          output.should contain("001-margins.pdf")
          output.should contain("lp -d EPSON_TM_m30III -n 1")
        end
      end
    end
  end

  it "renders the built-in simulate margin calibration sheet into the current directory" do
    with_cli_temp_dir do |dir|
      fake_png = File.join(dir, "content.png")
      fake_typst = File.join(dir, "typst")
      xdg_config = File.join(dir, "xdg")
      Bon::Simulate.write_png(fake_png, 2, 1, Bytes[0, 0, 0, 255, 255, 255])
      File.write(fake_typst, <<-SH)
        #!/bin/sh
        output=""
        for arg do
          output="$arg"
        done
        cp "$BON_FAKE_PNG" "$output"
        SH
      File.chmod(fake_typst, 0o755)
      stdout = IO::Memory.new
      stderr = IO::Memory.new

      with_cli_env({"BON_FAKE_PNG" => fake_png, "XDG_CONFIG_HOME" => xdg_config}) do
        Dir.cd(dir) do
          expected_output = File.join(Dir.current, "margins_80mm-printout.png")

          status = Bon::Cli.run(["s", "margins", "--typst-bin=#{fake_typst}", "--top-mm=0", "--bottom-mm=0"], stdout, stderr)

          status.should eq(0)
          stderr.to_s.should eq("")
          stdout.to_s.strip.should eq(expected_output)
          File.exists?(expected_output).should be_true
        end
      end
    end
  end

  it "dry-runs LaTeX printing through a PDF-first cropped CUPS job" do
    with_cli_temp_dir do |dir|
      source = File.join(dir, "receipt.tex")
      File.write(source, "\\documentclass{article}\\begin{document}Hello\\end{document}\n")
      File.write(File.join(dir, "bon.toml"), "[render]\nlatex_engine = \"pdflatex\"\n")
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
          output.should contain("-dDEVICEWIDTHPOINTS=204.296")
          output.should contain("lp -d EPSON_TM_m30III -n 1")
          output.should contain("-o media=Custom.204.296x300")
          output.should contain("-o Resolution=203x203dpi")
          output.should contain("001-receipt-print.pdf")
          output.should_not contain("001-receipt-print.png")
          output.should_not contain("pngmono")
          output.should_not contain("pnggray")
        end
      end
    end
  end

  it "dry-runs multi-page PDFs with per-page media heights" do
    with_cli_temp_dir do |dir|
      source = File.join(dir, "variable-pages.pdf")
      File.write(source, <<-PDF)
        %PDF-1.7
        1 0 obj <</MediaBox [0 0 100 120]>> endobj
        2 0 obj <</MediaBox [0 0 100 240]>> endobj
        PDF
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
          output.should contain("-dFirstPage=1")
          output.should contain("-dFirstPage=2")
          output.should contain("-o media=Custom.100x120")
          output.should contain("-o media=Custom.100x240")
          output.should contain("001-variable-pages-print-page-001.pdf")
          output.should contain("001-variable-pages-print-page-002.pdf")
        end
      end
    end
  end

  it "dry-runs PDF stdin with binary auto-detection" do
    with_cli_temp_dir do |dir|
      install_fake_lpstat(dir)
      install_fake_print_tools(dir)
      stdout = IO::Memory.new
      stderr = IO::Memory.new
      stdin = IO::Memory.new("%PDF-1.7\n1 0 obj <</MediaBox [0 0 100 120]>> endobj\n")

      with_cli_env({"PATH" => "#{dir}:#{ENV["PATH"]}", "XDG_CONFIG_HOME" => File.join(dir, "xdg")}) do
        status = Bon::Cli.run(["--dry-run", "-"], stdout, stderr, stdin)

        status.should eq(0)
        stderr.to_s.should eq("")
        output = stdout.to_s
        output.should contain("lp -d EPSON_TM_m30III -n 1")
        output.should contain("-o media=Custom.100x120")
        output.should contain("stdin.pdf")
      end
    end
  end

  it "dry-runs a single path piped through stdin" do
    with_cli_temp_dir do |dir|
      source = File.join(dir, "receipt.pdf")
      File.write(source, "%PDF-1.7\n1 0 obj <</MediaBox [0 0 100 120]>> endobj\n")
      install_fake_lpstat(dir)
      install_fake_print_tools(dir)
      stdout = IO::Memory.new
      stderr = IO::Memory.new
      stdin = IO::Memory.new("#{source}\n")

      with_cli_env({"PATH" => "#{dir}:#{ENV["PATH"]}", "XDG_CONFIG_HOME" => File.join(dir, "xdg")}) do
        status = Bon::Cli.run(["--dry-run", "-"], stdout, stderr, stdin)

        status.should eq(0)
        stderr.to_s.should eq("")
        output = stdout.to_s
        output.should contain("lp -d EPSON_TM_m30III -n 1")
        output.should contain("-o media=Custom.100x120")
        output.should contain(source)
        output.should_not contain("stdin.pdf")
      end
    end
  end

  it "dry-runs multiple paths piped through stdin with CLI path arguments" do
    with_cli_temp_dir do |dir|
      first = File.join(dir, "first.pdf")
      second = File.join(dir, "second.pdf")
      third = File.join(dir, "third.pdf")
      File.write(first, "%PDF-1.7\n1 0 obj <</MediaBox [0 0 100 120]>> endobj\n")
      File.write(second, "%PDF-1.7\n1 0 obj <</MediaBox [0 0 120 140]>> endobj\n")
      File.write(third, "%PDF-1.7\n1 0 obj <</MediaBox [0 0 140 160]>> endobj\n")
      install_fake_lpstat(dir)
      install_fake_print_tools(dir)
      stdout = IO::Memory.new
      stderr = IO::Memory.new
      stdin = IO::Memory.new("#{second}\n\n#{third}\n")

      with_cli_env({"PATH" => "#{dir}:#{ENV["PATH"]}", "XDG_CONFIG_HOME" => File.join(dir, "xdg")}) do
        status = Bon::Cli.run(["--dry-run", first, "-"], stdout, stderr, stdin)

        status.should eq(0)
        stderr.to_s.should eq("")
        output = stdout.to_s
        output.should contain("-o media=Custom.100x120")
        output.should contain("-o media=Custom.120x140")
        output.should contain("-o media=Custom.140x160")
        output.should contain(first)
        output.should contain(second)
        output.should contain(third)
      end
    end
  end

  it "dry-runs Typst stdin when explicitly typed" do
    with_cli_temp_dir do |dir|
      install_fake_lpstat(dir)
      install_fake_print_tools(dir)
      stdout = IO::Memory.new
      stderr = IO::Memory.new
      stdin = IO::Memory.new("#set page(width: 80mm, height: 300pt)\nHello\n")

      with_cli_env({"PATH" => "#{dir}:#{ENV["PATH"]}", "XDG_CONFIG_HOME" => File.join(dir, "xdg")}) do
          status = Bon::Cli.run(["--dry-run", "--stdin-format", "typ", "-"], stdout, stderr, stdin)

        status.should eq(0)
        stderr.to_s.should eq("")
        output = stdout.to_s
        output.should contain("typst compile --root")
        output.should contain("001-stdin.pdf")
        output.should contain("001-stdin-print.pdf")
      end
    end
  end

  it "dry-runs LaTeX stdin when explicitly typed" do
    with_cli_temp_dir do |dir|
      File.write(File.join(dir, "bon.toml"), "[render]\nlatex_engine = \"pdflatex\"\n")
      install_fake_lpstat(dir)
      install_fake_print_tools(dir)
      stdout = IO::Memory.new
      stderr = IO::Memory.new
      stdin = IO::Memory.new("\\documentclass{article}\\begin{document}Hello\\end{document}\n")

      with_cli_env({"PATH" => "#{dir}:#{ENV["PATH"]}", "XDG_CONFIG_HOME" => File.join(dir, "xdg")}) do
        Dir.cd(dir) do
          status = Bon::Cli.run(["--dry-run", "-f", "tex", "-"], stdout, stderr, stdin)

          status.should eq(0)
          stderr.to_s.should eq("")
          output = stdout.to_s
          output.should contain("pdflatex -interaction=nonstopmode")
          output.should contain("001-stdin.pdf")
          output.should contain("001-stdin-print.pdf")
        end
      end
    end
  end

  it "dry-runs PNG stdin with binary auto-detection" do
    with_cli_temp_dir do |dir|
      install_fake_lpstat(dir)
      install_fake_print_tools(dir)
      stdout = IO::Memory.new
      stderr = IO::Memory.new
      stdin = IO::Memory.new(png_header_bytes(100, 50))

      with_cli_env({"PATH" => "#{dir}:#{ENV["PATH"]}", "XDG_CONFIG_HOME" => File.join(dir, "xdg")}) do
        status = Bon::Cli.run(["--dry-run", "-"], stdout, stderr, stdin)

        status.should eq(0)
        stderr.to_s.should eq("")
        output = stdout.to_s
        output.should contain("lp -d EPSON_TM_m30III -n 1")
        output.should contain("-o media=Custom.72x72")
        output.should contain("stdin.png")
        output.should_not contain("typst compile")
        output.should_not contain("gs -q")
      end
    end
  end

  it "rejects undetectable text stdin without --stdin-format" do
    with_cli_temp_dir do |dir|
      install_fake_lpstat(dir)
      install_fake_print_tools(dir)
      stdout = IO::Memory.new
      stderr = IO::Memory.new
      stdin = IO::Memory.new("#set page(width: 80mm)\nHello\n")

      with_cli_env({"PATH" => "#{dir}:#{ENV["PATH"]}", "XDG_CONFIG_HOME" => File.join(dir, "xdg")}) do
        status = Bon::Cli.run(["--dry-run", "-"], stdout, stderr, stdin)

        status.should eq(2)
        stdout.to_s.should eq("")
        stderr.to_s.should contain("error: Could not detect stdin input type or path list; pass --stdin-format=pdf|png|jpg|jpeg|typ|tex for document content")
      end
    end
  end

  it "rejects invalid --stdin-format before printer discovery" do
    stdout = IO::Memory.new
    stderr = IO::Memory.new
    stdin = IO::Memory.new("%PDF-1.7\n")

    status = Bon::Cli.run(["--dry-run", "--stdin-format", "gif", "-"], stdout, stderr, stdin)

    status.should eq(2)
    stdout.to_s.should eq("")
    stderr.to_s.should contain("error: --stdin-format must be one of: pdf, png, jpg, jpeg, typ, tex")
  end

  it "rejects multiple stdin sources before reading stdin" do
    stdout = IO::Memory.new
    stderr = IO::Memory.new
    stdin = IO::Memory.new("%PDF-1.7\n")

    status = Bon::Cli.run(["--dry-run", "-", "-"], stdout, stderr, stdin)

    status.should eq(2)
    stdout.to_s.should eq("")
    stderr.to_s.should contain("error: stdin input can only be used once")
  end

  it "rejects empty stdin" do
    with_cli_temp_dir do |dir|
      install_fake_lpstat(dir)
      install_fake_print_tools(dir)
      stdout = IO::Memory.new
      stderr = IO::Memory.new
      stdin = IO::Memory.new

      with_cli_env({"PATH" => "#{dir}:#{ENV["PATH"]}", "XDG_CONFIG_HOME" => File.join(dir, "xdg")}) do
        status = Bon::Cli.run(["--dry-run", "--stdin-format", "pdf", "-"], stdout, stderr, stdin)

        status.should eq(2)
        stdout.to_s.should eq("")
        stderr.to_s.should contain("error: stdin input is empty")
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
    printf '%s\n' 'TmxPaperCut/Paper Cut: NoCut CutPerJob *CutPerPage'
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

private def install_fake_editor(dir : String, body : String) : Nil
  path = File.join(dir, "bon-test-editor")
  File.write(path, <<-SH)
    #!/bin/sh
    #{body}
    SH
  File.chmod(path, 0o755)
end

private def png_header_bytes(width : Int32, height : Int32) : Bytes
  png = IO::Memory.new
  png.write(Bytes[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
  png.write(Bytes[0x00, 0x00, 0x00, 0x0d])
  png.write("IHDR".to_slice)
  png.write_byte((width >> 24).to_u8)
  png.write_byte((width >> 16).to_u8)
  png.write_byte((width >> 8).to_u8)
  png.write_byte(width.to_u8)
  png.write_byte((height >> 24).to_u8)
  png.write_byte((height >> 16).to_u8)
  png.write_byte((height >> 8).to_u8)
  png.write_byte(height.to_u8)
  png.write(Bytes[0x08, 0x02, 0x00, 0x00, 0x00])
  png.write(Bytes[0x00, 0x00, 0x00, 0x00])
  png.to_slice
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
