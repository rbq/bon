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
      paper_cut = "NoCut"

      [paper]
      width_mm = 80.0
    TOML

    values["printer.name"].should eq("EPSON_TM_m30III__USB_")
    values["printer.candidates"].should eq(["A", "B"])
    values["cups.copies"].should eq(2_i64)
    values["cups.dry_run"].should eq(true)
    values["cups.paper_cut"].should eq("NoCut")
    values["paper.width_mm"].should eq(80.0)
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

      [cups.options]
      Resolution = "180x180dpi"
      SomeFlag = true
    TOML

    config.printer_candidates.should eq(["LOCAL"])
    config.printable_width_pt.should eq(149.1)
    config.typst_mode.should eq("raster")
    config.raster_ppi_multiplier.should eq(3)
    config.cups_options["Resolution"].should eq("180x180dpi")
    config.cups_options["SomeFlag"].should eq("true")
  end

  it "includes the raster PPI multiplier in generated TOML defaults" do
    Bon::Config.default_toml.should contain("raster_ppi_multiplier = 2")
  end

  it "defaults Typst input preparation to PDF mode" do
    Bon::Config.default_toml.should contain("typst_mode = \"pdf\"")
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

    defaults.should contain("paper_cut = \"CutPerPage\"")
    defaults.should_not contain("TmxPaperCut")
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

  it "allows disabling the first-class paper cut option" do
    config = Bon::Config.new

    config.overlay(Bon::Toml.parse(<<-TOML))
      [cups]
      paper_cut = ""
    TOML

    config.cups_paper_cut.should be_nil
  end

  it "rejects unknown paper cut values" do
    config = Bon::Config.new(cups_paper_cut: "Sometimes")

    expect_raises(Bon::Error, /cups.paper_cut/) do
      config.validate!
    end
  end
end
