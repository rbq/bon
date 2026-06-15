require "spec"
require "../src/bon/image"

describe Bon::Image do
  it "reads PNG dimensions from IHDR" do
    File.tempfile("bon-image", ".png") do |file|
      file.write(Bytes[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
      file.write(Bytes[0x00, 0x00, 0x00, 0x0d])
      file.write("IHDR".to_slice)
      file.write(Bytes[0x00, 0x00, 0x01, 0x2c])
      file.write(Bytes[0x00, 0x00, 0x00, 0xc8])
      file.write(Bytes[0x08, 0x02, 0x00, 0x00, 0x00])
      file.write(Bytes[0x00, 0x00, 0x00, 0x00])
      file.flush

      dims = Bon::Image.dimensions(file.path)
      dims.width.should eq(300)
      dims.height.should eq(200)
    end
  end

  it "computes physical page size from configured image PPI" do
    config = Bon::Config.new(image_ppi: 200)
    File.tempfile("bon-image", ".png") do |file|
      file.write(Bytes[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
      file.write(Bytes[0x00, 0x00, 0x00, 0x0d])
      file.write("IHDR".to_slice)
      file.write(Bytes[0x00, 0x00, 0x00, 0xc8])
      file.write(Bytes[0x00, 0x00, 0x00, 0x64])
      file.write(Bytes[0x08, 0x02, 0x00, 0x00, 0x00])
      file.write(Bytes[0x00, 0x00, 0x00, 0x00])
      file.flush

      size = Bon::Image.page_size(file.path, config)
      size.width.should eq(72.0)
      size.height.should eq(36.0)
    end
  end
end
