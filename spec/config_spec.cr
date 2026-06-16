require "spec"
require "../src/bon/config"

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
    TOML

    values["printer.name"].should eq("EPSON_TM_m30III__USB_")
    values["printer.candidates"].should eq(["A", "B"])
    values["cups.copies"].should eq(2_i64)
    values["cups.dry_run"].should eq(true)
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
end
