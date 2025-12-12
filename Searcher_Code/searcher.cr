require "colorize"
require "option_parser"

class Searcher
  class Config
    property after_context : Int32 = 0
    property before_context : Int32 = 0
    property color : Bool = false
    property hidden : Bool = false
    property ignore_case : Bool = false
    property no_heading : Bool = false
  end

  def initialize
    @config = Config.new
    @pattern = ""
    @paths = [] of String
    # Track if we have printed matches for *any* file yet. 
    # This is used to determine if we need a separator between files in no-heading mode with context.
    @has_printed_match = false
  end

  def run
    parse_options
    
    # Compile pattern to Regex
    regex_options = @config.ignore_case ? Regex::Options::IGNORE_CASE : Regex::Options::None
    
    begin
      # FIX: Pass @pattern directly to Regex.new without escaping to allow regex syntax.
      search_regex = Regex.new(@pattern, regex_options)
    rescue ex : ArgumentError
      STDERR.puts "Error: Invalid regular expression '#{@pattern}' - #{ex.message}".colorize(:red)
      exit(1)
    end

    @paths.each do |path|
      if File.file?(path)
        scan_file(path, search_regex)
      elsif File.directory?(path)
        scan_directory(path, search_regex)
      else
        STDERR.puts "Error: Path not found - #{path}".colorize(:red)
      end
    end
  end

  private def context_enabled?
    @config.after_context > 0 || @config.before_context > 0
  end

  private def parse_options
    OptionParser.parse do |parser|
      parser.banner = "usage: searcher [OPTIONS] PATTERN [PATH ...]"

      parser.on "-A", "--after-context <arg>", "prints the given number of following lines for each match" do |arg|
        @config.after_context = arg.to_i
      end
      parser.on "-B", "--before-context <arg>", "prints the given number of preceding lines for each match" do |arg|
        @config.before_context = arg.to_i
      end
      parser.on "-c", "--color", "print with colors, highlighting the matched phrase in the output" do
        @config.color = true
      end
      parser.on "-C", "--context <arg>", "prints the number of preceding and following lines for each match. this is equivalent to setting --before-context and --after-context" do |arg|
        val = arg.to_i
        @config.after_context = val
        @config.before_context = val
      end
      parser.on "-h", "--hidden", "search hidden files and folders" do
        @config.hidden = true
      end
      parser.on "--help", "Show help" do
        puts parser
        exit
      end
      parser.on "-i", "--ignore-case", "search case insensitive" do
        @config.ignore_case = true
      end
      parser.on "--no-heading", "prints a single line including the filename for each match, instead of grouping matches by file" do
        @config.no_heading = true
      end
      parser.on "-v", "--version", "Show version" do
        puts "searcher 1.0
Copyright (C) 2025-2026 Mehrshad Kavousi
License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>.
This is free software: you are free to change and redistribute it.
There is NO WARRANTY, to the extent permitted by law."
        exit
      end

      parser.missing_option do |option_flag|
        STDERR.puts "ERROR: #{option_flag} is missing something."
        STDERR.puts parser
        exit(1)
      end
      parser.invalid_option do |option_flag|
        STDERR.puts "ERROR: #{option_flag} is not a valid option."
        STDERR.puts parser
        exit(1)
      end
      parser.unknown_args do |args|
        if args.empty?
          STDERR.puts "Error: PATTERN is required"
          STDERR.puts parser
          exit(1)
        end

        # We assume arguments at the end that exist on disk are paths.
        # Everything before that is the pattern.
        detected_paths = [] of String
        
        while args.size > 1 && (File.exists?(args.last) || File.directory?(args.last))
          detected_paths.unshift(args.pop)
        end

        # If we consumed all args as paths (e.g. searching for a filename that exists),
        # the first "path" is actually the pattern.
        if args.empty?
           @pattern = detected_paths.shift
        else
           # Join remaining args to form the pattern (e.g. "Sherlock" + " " + "Holmes")
           @pattern = args.join(" ")
        end

        # If no paths were detected, default to current directory "."
        @paths = detected_paths.empty? ? ["."] : detected_paths
      end
    end
  end

  private def scan_directory(dir : String, regex : Regex)
    match_opts = @config.hidden ? File::MatchOptions::DotFiles : File::MatchOptions::None
    
    Dir.glob(File.join(dir, "**", "*"), match: match_opts) do |entry|
      # Skip symbolic links
      next if File.symlink?(entry)
      next if File.directory?(entry)
      
      scan_file(entry, regex)
    end
  end

  private def scan_file(filename : String, regex : Regex)
    # We use a Deque (double-ended queue) to store the "before" context lines
    before_buffer = Deque(Tuple(String, Int32)).new(@config.before_context + 1)
    
    # State tracking
    lines_to_print_after = 0
    last_printed_line_index = -1
    file_header_printed = false

    File.open(filename) do |file|
      file.each_line.with_index do |line, index|
        
        # 1. Binary / Encoding Checks
        if !line.valid_encoding? || line.includes?('\u0000')
          # If we hit binary data, we stop processing this file to match grep/rg behavior
          return
        end

        is_match = false
        # We need to rescue regex errors in case of edge-case binary sequences
        begin
          is_match = !regex.match(line).nil?
        rescue
          return
        end

        if is_match
          # --- HANDLE MATCH ---

          # 1. Print File Header (only once, if we found a match)
          if !@config.no_heading && !file_header_printed
            puts filename.colorize(:magenta).bold
            file_header_printed = true
          end

          # 2. Handle Separator (--) for non-adjacent matches
          # If there was a gap between the last printed line and this current match's context start
          # Note: We look at the 'buffer' to see where the context effectively starts
          buffer_start_index = before_buffer.empty? ? index : before_buffer.first[1]
          
          should_print_separator = context_enabled? && 
                                   last_printed_line_index != -1 && 
                                   buffer_start_index > last_printed_line_index + 1

          if should_print_separator
            puts "--"
          end

          # 3. Print the Separator between files (if this is the very first match of a new file in no-heading mode)
          if @config.no_heading && context_enabled? && @has_printed_match && !file_header_printed
             puts "--"
             file_header_printed = true # Mark as handled so we don't print it again for this file
          end
          @has_printed_match = true
          file_header_printed = true # Ensure we mark header as handled

          # 4. Print "Before" Context (buffered lines)
          while !before_buffer.empty?
            buf_line, buf_idx = before_buffer.shift
            print_line(buf_line, buf_idx, false, filename, regex)
            last_printed_line_index = buf_idx
          end

          # 5. Print Current Match
          print_line(line, index, true, filename, regex)
          last_printed_line_index = index
          
          # 6. Reset "After" Context Counter
          lines_to_print_after = @config.after_context

        else
          # --- HANDLE NO MATCH ---

          if lines_to_print_after > 0
            # We are inside the "After" context of a previous match
            print_line(line, index, false, filename, regex)
            last_printed_line_index = index
            lines_to_print_after -= 1
          else
            # We are not printing, so we buffer this line for potential "Before" context
            if @config.before_context > 0
              before_buffer << {line, index}
              # Keep buffer size limited
              if before_buffer.size > @config.before_context
                before_buffer.shift
              end
            end
          end
        end
      end
    end
  rescue ex : File::AccessDeniedError
    STDERR.puts "Warning: Could not read #{filename} (Permission denied)"
  rescue ex
    # Handle other file read errors gracefully
  end

  # Helper to format and print a single line
  private def print_line(content : String, index : Int32, is_match : Bool, filename : String, regex : Regex)
    line_num = index + 1
    separator = is_match ? ":" : "-"

    # Colorize match content
    final_content = content
    if @config.color && is_match
       begin
         final_content = content.gsub(regex) do |m| 
           m.colorize(:red).bold.on(:yellow).to_s 
         end
       rescue
       end
    end

    line_num_str = line_num.to_s.colorize(:green)

    if @config.no_heading
      fname = filename.colorize(:magenta)
      puts "#{fname}#{separator}#{line_num_str}#{separator}#{final_content}"
    else
      puts "#{line_num_str}#{separator}#{final_content}"
    end
  end
end

# Entry point
Searcher.new.run
