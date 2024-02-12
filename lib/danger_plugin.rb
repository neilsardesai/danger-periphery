# frozen_string_literal: true

require 'periphery'

module Danger
  # Analyze Swift files and detect unused codes in your project.
  # This is done using {https://github.com/peripheryapp/periphery Periphery}.
  #
  # @example Specifying options to Periphery.
  #
  #          periphery.scan(
  #            project: "Foo.xcodeproj"
  #            schemes: ["foo", "bar"],
  #            targets: "foo",
  #            clean_build: true
  #          )
  #
  # @see file:README.md
  # @tags swift
  class DangerPeriphery < Plugin
    # Path to Periphery executable.
    # By default the value is nil and the executable is searched from $PATH.
    # @return [String]
    attr_accessor :binary_path

    # @deprecated Use {#scan} with block instead.
    #
    # Proc object to process each warnings just before showing them.
    # The Proc must receive 4 arguments: path, line, column, message
    # and return one of:
    #   - an array that contains 4 elements [path, line, column, message]
    #   - true
    #   - false
    #   - nil
    # If Proc returns an array, the warning will be raised based on returned elements.
    # If Proc returns true, the warning will not be modified.
    # If Proc returns false or nil, the warning will be ignored.
    #
    # By default the Proc returns true.
    # @return [Proc]
    attr_reader :postprocessor

    # For internal use only.
    #
    # @return [Symbol]
    attr_writer :format

    OPTION_OVERRIDES = {
      disable_update_check: true,
      quiet: true
    }.freeze

    def initialize(dangerfile)
      super(dangerfile)
      @postprocessor = ->(_path, _line, _column, _message) { true }
      @format = :checkstyle
    end

    # Scans Swift files.
    # Raises an error when Periphery executable is not found.
    #
    # @example Ignore all warnings from files matching regular expression
    #   periphery.scan do |violation|
    #     !violation.path.match(/.*\/generated\.swift/)
    #   end
    #
    # @param [Hash] options Options passed to Periphery with the following translation rules.
    #                       1. Replace all underscores with hyphens in each key.
    #                       2. Prepend double hyphens to each key.
    #                       3. If value is an array, transform it to comma-separated string.
    #                       4. If value is true, drop value and treat it as option without argument.
    #                       5. Override some options listed in {OPTION_OVERRIDES}.
    #                       Run +$ periphery help scan+ for available options.
    #
    # @param [Proc] block   Block to process each warning just before showing it.
    #                       The Proc receives 1 {Periphery::ScanResult} instance as argument.
    #                       If the Proc returns falsy value, the warning corresponding to the given ScanResult will be
    #                       suppressed, otherwise not.
    #
    # @return [void]
    def scan(options = {}, &block)
      output = Periphery::Runner.new(binary_path).scan(options.merge(OPTION_OVERRIDES).merge(format: @format))

      parser.parse(output).each do |entry|
        result = postprocess(entry, &block)
        next unless result

        path, line, _column, message = result
        warn("#{message} in #{entry.path}")
      end
    end

    # @deprecated Use {#scan} with block instead.
    #
    # Convenience method to set {#postprocessor} with block.
    #
    # @return [Proc]
    def process_warnings(&block)
      deprecate_in_favor_of_scan
      @postprocessor = block
    end

    # @deprecated Use {#scan} with block instead.
    #
    # A block to manipulate each warning before it is displayed.
    #
    # @param [Proc] postprocessor Block to process each warning just before showing it.
    #                             The Proc is called like `postprocessor(path, line, column, message)`
    #                             where `path` is a String that indicates the file path the warning points out,
    #                             `line` and `column` are Integers that indicates the location in the file,
    #                             `message` is a String message body of the warning.
    #                             The Proc returns either of the following:
    #                             1. an Array contains `path`, `line`, `column`, `message` in this order.
    #                             2. true
    #                             3. false or nil
    #                             If it returns falsy value, the warning will be suppressed.
    #                             If it returns `true`, the warning will be displayed as-is.
    #                             Otherwise it returns an Array, the warning is newly created by the returned array
    #                             and displayed.
    # @return [void]
    def postprocessor=(postprocessor)
      deprecate_in_favor_of_scan
      @postprocessor = postprocessor
    end

    # Download and install Periphery executable binary.
    #
    # @param [String, Symbol] version The version of Periphery you want to install.
    #                                 `:latest` is treated as special keyword that specifies the latest version.
    # @param [String] path            The path to install Periphery including the filename itself.
    # @param [Boolean] force          If `true`, an existing file will be overwritten. Otherwise an error occurs.
    # @return [void]
    def install(version: :latest, path: 'periphery', force: false)
      installer = Periphery::Installer.new(version)
      installer.install(path, force: force)
      self.binary_path = File.absolute_path(path)
    end

    private

    def files_in_diff
      # Taken from https://github.com/ashfurrow/danger-ruby-swiftlint/blob/5184909aab00f12954088684bbf2ce5627e08ed6/lib/danger_plugin.rb#L214-L216
      renamed_files_hash = git.renamed_files.to_h { |rename| [rename[:before], rename[:after]] }
      post_rename_modified_files = git.modified_files.map do |modified_file|
        renamed_files_hash[modified_file] || modified_file
      end
      (post_rename_modified_files - git.deleted_files) + git.added_files
    end

    def postprocess(entry, &block)
      if block
        postprocess_with_block(entry, &block)
      else
        postprocess_with_postprocessor(entry)
      end
    end

    def postprocess_with_block(entry, &block)
      [entry.path, entry.line, entry.column, entry.message] if block.call(entry)
    end

    def postprocess_with_postprocessor(entry)
      result = @postprocessor.call(entry.path, entry.line, entry.column, entry.message)
      if !result
        nil
      elsif result.is_a?(TrueClass)
        [entry.path, entry.line, entry.column, entry.message]
      elsif result.is_a?(Array) && result.size == 4
        result
      else
        raise 'Proc passed to postprocessor must return one of nil, true, false and Array that includes 4 elements.'
      end
    end

    def deprecate_in_favor_of_scan
      caller_method_name = caller(1, 1)[0].sub(/.*`(.*)'.*/, '\1')
      caller_location = caller_locations(2, 1)[0]
      message = [
        "`#{self.class}##{caller_method_name}` is deprecated; use `#{self.class}#scan` with block instead. ",
        'It will be removed from future releases.'
      ].join
      location_message = "#{self.class}##{caller_method_name} called from #{caller_location}"
      Kernel.warn("NOTE: #{message}\n#{location_message}")
      issue_reference = 'See manicmaniac/danger-periphery#37 for detail.'
      warn("#{message}\n#{issue_reference}", file: caller_location.path, line: caller_location.lineno)
    end

    def parser
      case @format
      when :checkstyle
        Periphery::CheckstyleParser.new
      when :json
        Periphery::JsonParser.new
      else
        raise "#{@format} is unsupported"
      end
    end
  end
end
