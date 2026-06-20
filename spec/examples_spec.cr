require "spec"

require "../src/bon/document"
require "../src/bon/simulate"

describe "spec examples" do
  examples_dir = File.expand_path("../examples/spec", __DIR__)

  it "provides one local input for every supported document suffix" do
    suffixes = Dir.children(examples_dir).map { |path| File.extname(path).downcase }.uniq.sort

    Bon::Document::SUPPORTED_SUFFIXES.each do |suffix|
      suffixes.should contain(suffix)
    end
  end

  it "keeps all example inputs valid for document resolution" do
    Bon::Document::SUPPORTED_SUFFIXES.each do |suffix|
      path = Dir.glob(File.join(examples_dir, "*#{suffix}")).first
      path.should_not be_nil
      Bon::Document.validate(path.not_nil!)
    end
  end

  it "covers image dimensions for PNG, JPG, and JPEG examples" do
    Bon::Image.dimensions(File.join(examples_dir, "receipt.png")).should eq(Bon::Image::Dimensions.new(384, 96))
    Bon::Image.dimensions(File.join(examples_dir, "receipt.jpg")).should eq(Bon::Image::Dimensions.new(384, 96))
    Bon::Image.dimensions(File.join(examples_dir, "receipt.jpeg")).should eq(Bon::Image::Dimensions.new(576, 144))
  end

  it "covers variable page heights in a PDF example" do
    pages = Bon::PDF.page_sizes(File.join(examples_dir, "variable-pages.pdf"))

    pages.should eq([
      Bon::PDF::PageSize.new(226.77165, 140.0),
      Bon::PDF::PageSize.new(226.77165, 280.0),
    ])
  end

  it "uses the examples directory for default simulation discovery" do
    sources = Bon::Simulate.default_sources(examples_dir).map { |path| File.basename(path) }

    sources.should eq([
      "label-58mm.typ",
      "receipt-80mm.typ",
      "receipt.jpeg",
      "receipt.jpg",
      "receipt.png",
      "variable-pages.typ",
    ])
  end
end
