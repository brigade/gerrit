require 'childprocess'
require 'tempfile'

module Gerrit
  # Manages execution of a child process, collecting the exit status and
  # standard out/error output.
  class Subprocess
    # Encapsulates the result of a process.
    #
    # @attr_reader status [Integer] exit status code returned by process
    # @attr_reader stdout [String] standard output stream output
    # @attr_reader stderr [String] standard error stream output
    Result = Struct.new(:status, :stdout, :stderr) do
      def success?
        status == 0
      end
    end

    class << self
      # Spawns a new process using the given array of arguments (the first
      # element is the command).
      #
      # @param args [Array<String>]
      # @return [Result]
      def spawn(args)
        process = ChildProcess.build(*args)

        out, err = assign_output_streams(process)

        process.start
        process.wait

        err.rewind
        out.rewind

        Result.new(process.exit_code, out.read, err.read)
      end

      private

      # @param process [ChildProcess]
      # @return [Array<IO>]
      def assign_output_streams(process)
        %w[out err].map do |stream_name|
          ::Tempfile.new(stream_name).tap do |stream|
            stream.sync = true
            process.io.send("std#{stream_name}=", stream)
          end
        end
      end
    end
  end
end
