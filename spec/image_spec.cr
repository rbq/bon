require "file_utils"
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

  it "wraps images with the temporary directory as the Typst root" do
    with_image_temp_dir do |dir|
      source_dir = File.join(dir, "source")
      temp_dir = File.join(dir, "typst-root")
      FileUtils.mkdir_p(source_dir)
      FileUtils.mkdir_p(temp_dir)
      source = File.join(source_dir, "receipt.png")
      output = File.join(temp_dir, "wrapped.pdf")
      fake_typst = File.join(dir, "typst")
      stdout = IO::Memory.new
      stderr = IO::Memory.new

      write_spec_png(source, 1, 1)
      File.write(fake_typst, <<-SH)
        #!/bin/sh
        output=""
        for arg do
          output="$arg"
        done
        printf '%s\n' '%PDF-1.7' '1 0 obj <</MediaBox [0 0 1 1]>> endobj' > "$output"
        SH
      File.chmod(fake_typst, 0o755)

      Bon::Image.wrap_as_typst_pdf(source, output, temp_dir, Bon::Config.new(typst_bin: fake_typst), true, stdout, stderr)

      stdout.to_s.should contain("--root #{temp_dir}")
      stdout.to_s.should_not contain("--root #{source_dir}")
      File.read(File.join(temp_dir, "image-wrapper.typ")).should contain("#image(\"source.png\"")
      File.exists?(File.join(temp_dir, "source.png")).should be_true
    end
  end
end

private def write_spec_png(path : String, width : Int32, height : Int32) : Nil
  File.open(path, "w") do |file|
    file.write(Bytes[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
    file.write(Bytes[0x00, 0x00, 0x00, 0x0d])
    file.write("IHDR".to_slice)
    file.write_bytes(width.to_u32, IO::ByteFormat::BigEndian)
    file.write_bytes(height.to_u32, IO::ByteFormat::BigEndian)
    file.write(Bytes[0x08, 0x02, 0x00, 0x00, 0x00])
    file.write(Bytes[0x00, 0x00, 0x00, 0x00])
  end
end

private def with_image_temp_dir(& : String ->) : Nil
  dir = File.join(Dir.tempdir, "bon-image-spec-#{Process.pid}-#{Time.utc.to_unix_ns}-#{Random.rand(1_000_000)}")
  Dir.mkdir(dir)
  begin
    yield dir
  ensure
    FileUtils.rm_rf(dir)
  end
end
