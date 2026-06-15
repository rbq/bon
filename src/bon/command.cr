module Bon
  module Command
    def self.require_executable(name : String) : String
      Process.find_executable(name) || raise Error.new("Required command not found: #{name}")
    end

    def self.run(command : Array(String), failure_message : String, dry_run = false, execute_during_dry_run = false, output_io : IO = STDOUT, error_io : IO = STDERR) : Nil
      output_io.puts(shell_join(command)) if dry_run
      return if dry_run && !execute_during_dry_run

      stdout = IO::Memory.new
      stderr = IO::Memory.new
      status = Process.run(command[0], command[1..], output: stdout, error: stderr)
      output_io.print(stdout.to_s) unless stdout.empty?
      error_io.print(stderr.to_s) unless stderr.empty?
      raise Error.new(failure_message) unless status.success?
    end

    def self.run_capture(command : Array(String), failure_message : String) : String
      stdout = IO::Memory.new
      stderr = IO::Memory.new
      status = Process.run(command[0], command[1..], output: stdout, error: stderr)
      raise Error.new("#{failure_message}: #{stderr.to_s.strip}") unless status.success?
      stdout.to_s
    end

    def self.try_run(command : Array(String), output_io : IO = STDOUT, error_io : IO = STDERR) : Bool
      stdout = IO::Memory.new
      stderr = IO::Memory.new
      status = Process.run(command[0], command[1..], output: stdout, error: stderr)
      output_io.print(stdout.to_s) unless stdout.empty?
      error_io.print(stderr.to_s) unless stderr.empty?
      status.success?
    end

    def self.shell_join(command : Array(String)) : String
      command.map { |part| shell_escape(part) }.join(" ")
    end

    def self.shell_escape(value : String) : String
      return "''" if value.empty?
      return value if value.matches?(/\A[A-Za-z0-9_@%+=:,\.\/-]+\z/)
      "'#{value.gsub("'", "'\\''")}'"
    end
  end

  class Error < Exception
  end
end
