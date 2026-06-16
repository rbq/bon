require "spec"
require "../src/bon/cups"

describe Bon::Cups do
  it "parses CUPS queues and marks disabled printers unusable" do
    queues = Bon::Cups.parse_queues(<<-DEVICES, <<-STATUSES)
      device for EPSON_TM_m30III__USB_: usb://EPSON/TM-m30III
      device for Office: ipp://office/printer
    DEVICES
      printer EPSON_TM_m30III__USB_ is idle.  enabled since today
      printer Office disabled since today
    STATUSES

    queues.size.should eq(2)
    queues[0].name.should eq("EPSON_TM_m30III__USB_")
    queues[0].usable?.should be_true
    queues[0].thermal?.should be_true
    queues[1].usable?.should be_false
  end

  it "discovers a network thermal queue before an idle USB queue" do
    queues = [
      Bon::Cups::Queue.new("EPSON_TM_m30III__USB_", "usb://EPSON/TM-m30III", true, "is idle.  enabled since today"),
      Bon::Cups::Queue.new("EPSON_TM_m30III", "dnssd://EPSON%20TM-m30III._printer._tcp.local/", true, "is idle.  enabled since today"),
    ]

    Bon::Cups.discover(Bon::Config.new, queues).name.should eq("EPSON_TM_m30III")
  end

  it "uses candidate order between queues with the same connection type" do
    config = Bon::Config.new(printer_candidates: ["Preferred", "Fallback"])
    queues = [
      Bon::Cups::Queue.new("Fallback", "ipp://fallback/printer", true, "is idle.  enabled since today"),
      Bon::Cups::Queue.new("Preferred", "ipp://preferred/printer", true, "is idle.  enabled since today"),
    ]

    Bon::Cups.discover(config, queues).name.should eq("Preferred")
  end

  it "keeps an explicit printer name authoritative" do
    config = Bon::Config.new(printer_name: "EPSON_TM_m30III__USB_")
    queues = [
      Bon::Cups::Queue.new("EPSON_TM_m30III__USB_", "usb://EPSON/TM-m30III", true, "is idle.  enabled since today"),
      Bon::Cups::Queue.new("EPSON_TM_m30III", "dnssd://EPSON%20TM-m30III._printer._tcp.local/", true, "is idle.  enabled since today"),
    ]

    Bon::Cups.discover(config, queues).name.should eq("EPSON_TM_m30III__USB_")
  end

  it "adds dynamic media unless a media-like option already exists" do
    config = Bon::Config.new
    options = Bon::Cups.build_options(config, Bon::PDF::PageSize.new(180.0, 300.0), {} of String => String)
    options["media"].should eq("Custom.180x300")
    options["ppi"].should eq("203")

    overridden = Bon::Cups.build_options(config, Bon::PDF::PageSize.new(180.0, 300.0), {"PageSize" => "RP80"})
    overridden.has_key?("media").should be_false
  end

  it "disables driver fit-to-page scaling by default" do
    config = Bon::Config.new
    options = Bon::Cups.build_options(config, Bon::PDF::PageSize.new(180.0, 300.0), {} of String => String)
    options["fit-to-page"].should eq("false")
  end

  it "cuts after each page by default" do
    config = Bon::Config.new
    options = Bon::Cups.build_options(config, Bon::PDF::PageSize.new(180.0, 300.0), {} of String => String)

    options["TmxPaperCut"].should eq("CutPerPage")
  end

  it "lets config and CLI options override paper cutting" do
    config = Bon::Config.new(cups_paper_cut: "NoCut")

    options = Bon::Cups.build_options(config, Bon::PDF::PageSize.new(180.0, 300.0), {} of String => String)
    options["TmxPaperCut"].should eq("NoCut")

    overridden = Bon::Cups.build_options(config, Bon::PDF::PageSize.new(180.0, 300.0), {"TmxPaperCut" => "CutPerJob"})
    overridden["TmxPaperCut"].should eq("CutPerJob")
  end

  it "cuts each page by default while allowing CUPS option overrides" do
    config = Bon::Config.new
    options = Bon::Cups.build_options(config, Bon::PDF::PageSize.new(180.0, 300.0), {} of String => String)
    options["TmxPaperCut"].should eq("CutPerPage")

    overridden = Bon::Cups.build_options(config, Bon::PDF::PageSize.new(180.0, 300.0), {"TmxPaperCut" => "CutPerJob"})
    overridden["TmxPaperCut"].should eq("CutPerJob")
  end

  it "lets CLI options override fit-to-page" do
    config = Bon::Config.new
    options = Bon::Cups.build_options(config, Bon::PDF::PageSize.new(180.0, 300.0), {"fit-to-page" => "true"})
    options["fit-to-page"].should eq("true")
  end

  it "lets CLI options override the generated image PPI" do
    config = Bon::Config.new(image_ppi: 203)
    options = Bon::Cups.build_options(config, Bon::PDF::PageSize.new(180.0, 300.0), {"ppi" => "180"})

    options["ppi"].should eq("180")
  end

  it "parses driver option keys and allowed values from lpoptions output" do
    supported = Bon::Cups.parse_driver_options(<<-OPTIONS)
      PageSize/Media Size: *RP80x200 RP80x2000 Custom.WIDTHxHEIGHT
      Resolution/Resolution: *203x203dpi
      TmxPaperReduction/Paper Reduction: Off Top *Bottom Both
      TmxPaperCut/Paper Cut: *NoCut CutPerJob CutPerPage
    OPTIONS

    supported["TmxPaperReduction"].should eq(["Off", "Top", "Bottom", "Both"])
    supported["TmxPaperCut"].should eq(["NoCut", "CutPerJob", "CutPerPage"])
    supported.has_key?("TmxPrintQuality").should be_false
  end

  it "rejects driver options that the printer does not support" do
    supported = {
      "TmxPaperReduction" => ["Off", "Top", "Bottom", "Both"],
      "TmxPaperCut"       => ["NoCut", "CutPerJob", "CutPerPage"],
    }

    expect_raises(Bon::Error, /TmxPrintQuality is not supported/) do
      Bon::Cups.validate_against!("EPSON_TM_m30III__USB_", {"TmxPrintQuality" => "SuperHigh"}, supported)
    end
  end

  it "rejects unsupported values for a real driver option" do
    supported = {"TmxPaperReduction" => ["Off", "Top", "Bottom", "Both"]}

    expect_raises(Bon::Error, /TmxPaperReduction=None is invalid/) do
      Bon::Cups.validate_against!("EPSON_TM_m30III__USB_", {"TmxPaperReduction" => "None"}, supported)
    end
  end

  it "accepts standard job options and custom media without a PPD entry" do
    supported = {"TmxPaperCut" => ["NoCut", "CutPerJob", "CutPerPage"]}

    options = {
      "media"       => "Custom.204.296x113.498",
      "ppi"         => "203",
      "fit-to-page" => "false",
      "TmxPaperCut" => "CutPerPage",
    }

    Bon::Cups.validate_against!("EPSON_TM_m30III__USB_", options, supported)
  end
end
