require "spec"
require "../src/bon/config"
require "../src/bon/pdf"

describe Bon::Toml do
  it "parses the supported scalar and array subset" do
    values = Bon::Toml.parse(<<-TOML)
      [printer]
      name = "EPSON_TM_m30III__USB_"
      candidates = ["A", "B"]

      [cups]
      copies = 2
      dry_run = true

      [paper]
      width_mm = 80.0

      [cups.options]
      TmxPaperCut = "NoCut"
    TOML

    values["printer.name"].should eq("EPSON_TM_m30III__USB_")
    values["printer.candidates"].should eq(["A", "B"])
    values["cups.copies"].should eq(2_i64)
    values["cups.dry_run"].should eq(true)
    values["paper.width_mm"].should eq(80.0)
    values["cups.options.TmxPaperCut"].should eq("NoCut")
  end
end

describe Bon::Config do
  it "overlays local scalar values, replaces candidates, and merges CUPS options" do
    config = Bon::Config.new
    config.overlay(Bon::Toml.parse(<<-TOML))
      [printer]
      candidates = ["LOCAL"]

      [paper]
      printable_width_pt = 149.1

      [render]
      typst_mode = "raster"
      raster_ppi_multiplier = 3
      raster_threshold = 0.5
      raster_dither = "ordered"

      [simulate]
      background_tint = "c8d0ff"
      foreground_color = "#112233"
      foreground_fade = 0.5

      [cups.options]
      Resolution = "180x180dpi"
      SomeFlag = true
    TOML

    config.printer_candidates.should eq(["LOCAL"])
    config.printable_width_pt.should eq(149.1)
    config.typst_mode.should eq("raster")
    config.raster_ppi_multiplier.should eq(3)
    config.raster_threshold.should eq(0.5)
    config.raster_dither.should eq("ordered")
    config.simulate_background_tint.should eq("c8d0ff")
    config.simulate_foreground_color.should eq("#112233")
    config.simulate_foreground_fade.should eq(0.5)
    config.cups_options["Resolution"].should eq("180x180dpi")
    config.cups_options["SomeFlag"].should eq("true")
  end

  it "includes raster controls in generated TOML defaults" do
    Bon::Config.default_toml.should contain("raster_ppi_multiplier = 2")
    Bon::Config.default_toml.should contain("raster_threshold = 0.125")
    Bon::Config.default_toml.should contain("raster_dither = \"none\"")
  end

  it "defaults Typst input preparation to PDF mode" do
    Bon::Config.default_toml.should contain("typst_mode = \"pdf\"")
  end

  it "includes the simulation background tint in generated TOML defaults" do
    Bon::Config.default_toml.should contain("[simulate]")
    Bon::Config.default_toml.should contain("background_tint = \"#f5f1e0\"")
  end

  it "includes simulate foreground defaults in generated TOML defaults" do
    defaults = Bon::Config.default_toml

    defaults.should contain("[simulate]")
    defaults.should contain("foreground_color = \"#232320\"")
    defaults.should contain("foreground_fade = 1.0")
  end

  it "uses automatic printable widths for common thermal paper sizes" do
    default = Bon::Config.new
    fifty_eight = Bon::Config.new(paper_width_mm: 58.0)

    Bon::PDF.format_points(default.printable_width_pt).should eq("204.296")
    Bon::PDF.format_points(fifty_eight.printable_width_pt).should eq("136.197")
  end

  it "lets printable width follow paper width when configured as automatic" do
    config = Bon::Config.new(printable_width_pt: 149.1)

    config.overlay(Bon::Toml.parse(<<-TOML))
      [paper]
      width_mm = 58.0
      printable_width_pt = 0.0
    TOML

    Bon::PDF.format_points(config.printable_width_pt).should eq("136.197")
  end

  it "rejects printable widths wider than the paper" do
    config = Bon::Config.new(paper_width_mm: 58.0, printable_width_pt: 204.3)

    expect_raises(Bon::Error, /printable_width_pt/) do
      config.validate!
    end
  end

  it "defaults thermal paper cutting to after each page" do
    defaults = Bon::Config.default_toml

    defaults.should contain("TmxPaperCut = \"CutPerPage\"")
    defaults.should_not contain("paper_cut")
  end

  it "does not force the USB printer in generated TOML defaults" do
    defaults = Bon::Config.default_toml

    defaults.should contain("# name = \"EPSON_TM_m30III\"")
    defaults.should contain("candidates = [\"EPSON_TM_m30III\", \"EPSON_TM_m30III__USB_\"]")
  end

  it "allows an empty printer name to restore automatic discovery" do
    config = Bon::Config.new(printer_name: "EPSON_TM_m30III__USB_")

    config.overlay(Bon::Toml.parse(<<-TOML))
      [printer]
      name = ""
    TOML

    config.printer_name.should be_nil
  end

  it "allows removing default CUPS options with an empty string" do
    config = Bon::Config.new

    config.overlay(Bon::Toml.parse(<<-TOML))
      [cups.options]
      TmxPaperCut = ""
    TOML

    config.cups_options.has_key?("TmxPaperCut").should be_false
  end

  it "rejects the removed legacy paper cut key" do
    config = Bon::Config.new

    expect_raises(Bon::Error, /Unknown config key cups\.paper_cut/) do
      config.overlay(Bon::Toml.parse(<<-TOML))
        [cups]
        paper_cut = "NoCut"
      TOML
    end
  end

  it "rejects invalid simulation background tint values" do
    config = Bon::Config.new(simulate_background_tint: "paper")

    expect_raises(Bon::Error, /simulate.background_tint/) do
      config.validate!
    end
  end

  it "rejects invalid simulate foreground settings" do
    expect_raises(Bon::Error, /simulate.foreground_color/) do
      Bon::Config.new(simulate_foreground_color: "black").validate!
    end

    expect_raises(Bon::Error, /simulate.foreground_fade/) do
      Bon::Config.new(simulate_foreground_fade: 1.1).validate!
    end
  end

  it "rejects invalid render executables and engines" do
    expect_raises(Bon::Error, /render.typst_bin/) do
      Bon::Config.new(typst_bin: "").validate!
    end

    expect_raises(Bon::Error, /render.latex_engine/) do
      Bon::Config.new(latex_engine: "xelatex").validate!
    end
  end

  it "rejects invalid raster controls" do
    expect_raises(Bon::Error, /render.raster_threshold/) do
      Bon::Config.new(raster_threshold: 1.1).validate!
    end

    expect_raises(Bon::Error, /render.raster_dither/) do
      Bon::Config.new(raster_dither: "floyd-steinberg").validate!
    end
  end

  it "rejects oversized integer config values" do
    config = Bon::Config.new

    expect_raises(Bon::Error, /outside the supported integer range/) do
      config.overlay(Bon::Toml.parse(<<-TOML))
        [cups]
        copies = 999999999999999999
      TOML
    end
  end
end
