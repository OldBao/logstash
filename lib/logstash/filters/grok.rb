require "logstash/filters/base"
require "logstash/namespace"
require "set"

# Parse arbitrary text and structure it.
#
# Grok is currently the best way in logstash to parse crappy unstructured log
# data into something structured and queryable.
#
# This tool is perfect for syslog logs, apache and other webserver logs, mysql
# logs, and in general, any log format that is generally written for humans
# and not computer consumption.
#
# Logstash ships with about 120 patterns by default. You can find them here:
# <https://github.com/logstash/logstash/tree/v%VERSION%/patterns>. You can add
# your own trivially. (See the patterns_dir setting)
#
# If you need help building patterns to match your logs, you will find the
# <http://grokdebug.herokuapp.com> too quite useful!
#
# #### Grok Basics
#
# Grok works by using combining text patterns into something that matches your
# logs.
#
# The syntax for a grok pattern is `%{SYNTAX:SEMANTIC}`
#
# The `SYNTAX` is the name of the pattern that will match your text. For
# example, "3.44" will be matched by the NUMBER pattern and "55.3.244.1" will
# be matched by the IP pattern. The syntax is how you match.
#
# The `SEMANTIC` is the identifier you give to the piece of text being matched.
# For example, "3.44" could be the duration of an event, so you could call it
# simply 'duration'. Further, a string "55.3.244.1" might identify the client
# making a request.
#
# Optionally you can add a data type conversion to your grok pattern. By default
# all semantics are saved as strings. If you wish to convert a semnatic's data type,
# for example change a string to an integer then suffix it with the target data type.
# For example `${NUMBER:num:int}` which converts the 'num' semantic from a string to an
# integer. Currently the only supporting conversions are `int` and `float`.
#
# #### Example
#
# With that idea of a syntax and semantic, we can pull out useful fields from a
# sample log like this fictional http request log:
#
#     55.3.244.1 GET /index.html 15824 0.043
#
# The pattern for this could be:
#
#     %{IP:client} %{WORD:method} %{URIPATHPARAM:request} %{NUMBER:bytes} %{NUMBER:duration}
#
# A more realistic example, let's read these logs from a file:
#
#     input {
#       file {
#         path => "/var/log/http.log"
#         type => "examplehttp"
#       }
#     }
#     filter {
#       grok {
#         type => "examplehttp"
#         pattern => "%{IP:client} %{WORD:method} %{URIPATHPARAM:request} %{NUMBER:bytes} %{NUMBER:duration}"
#       }
#     }
#
# After the grok filter, the event will have a few extra fields in it:
#
# * client: 55.3.244.1
# * method: GET
# * request: /index.html
# * bytes: 15824
# * duration: 0.043
#
# #### Regular Expressions
#
# Grok sits on top of regular expressions, so any regular expressions are valid
# in grok as well. The regular expression library is Oniguruma, and you can see
# the full supported regexp syntax [on the Onigiruma
# site](http://www.geocities.jp/kosako3/oniguruma/doc/RE.txt)
#
# #### Custom Patterns
#
# Sometimes logstash doesn't have a pattern you need. For this, you have
# a few options.
#
# First, you can use the Oniguruma syntax for 'named capture' which will
# let you match a piece of text and save it as a field:
#
#     (?<field_name>the pattern here)
#
# For example, postfix logs have a 'queue id' that is an 11-character
# hexadecimal value. I can capture that easily like this:
#
#     (?<queue_id>[0-9A-F]{11})
#
# Alternately, you can create a custom patterns file. 
#
# * Create a directory called `patterns` with a file in it called `extra`
#   (the file name doesn't matter, but name it meaningfully for yourself)
# * In that file, write the pattern you need as the pattern name, a space, then
#   the regexp for that pattern.
#
# For example, doing the postfix queue id example as above:
#
#     # in ./patterns/postfix 
#     POSTFIX_QUEUEID [0-9A-F]{11}
#
# Then use the `patterns_dir` setting in this plugin to tell logstash where
# your custom patterns directory is. Here's a full example with a sample log:
#
#     Jan  1 06:25:43 mailserver14 postfix/cleanup[21403]: BEF25A72965: message-id=<20130101142543.5828399CCAF@mailserver14.example.com>
#
#     filter {
#       grok {
#         patterns_dir => "./patterns"
#         pattern => "%{SYSLOGBASE} %{POSTFIX_QUEUEID:queue_id}: %{GREEDYDATA:message}"
#       }
#     }
#
# The above will match and result in the following fields:
#
# * timestamp: Jan  1 06:25:43
# * logsource: mailserver14
# * program: postfix/cleanup
# * pid: 21403
# * queue_id: BEF25A72965
#
# The `timestamp`, `logsource`, `program`, and `pid` fields come from the
# SYSLOGBASE pattern which itself is defined by other patterns.
class LogStash::Filters::Grok < LogStash::Filters::Base
  config_name "grok"
  plugin_status "stable"

  # Specify a pattern to parse with. This will match the '@message' field.
  #
  # If you want to match other fields than @message, use the 'match' setting.
  # Multiple patterns is fine.
  config :pattern, :validate => :array

  # A hash of matches of field => value
  #
  # For example:
  #
  #     filter {
  #       grok {
  #         match => [ "@message", "Duration: %{NUMBER:duration} ]
  #       }
  #     }
  #
  config :match, :validate => :hash, :default => {}

  #
  # logstash ships by default with a bunch of patterns, so you don't
  # necessarily need to define this yourself unless you are adding additional
  # patterns.
  #
  # Pattern files are plain text with format:
  #
  #     NAME PATTERN
  #
  # For example:
  #
  #     NUMBER \d+
  config :patterns_dir, :validate => :array, :default => []

  # Drop if matched. Note, this feature may not stay. It is preferable to combine
  # grok + grep filters to do parsing + dropping.
  #
  # requested in: googlecode/issue/26
  config :drop_if_match, :validate => :boolean, :default => false

  # Break on first match. The first successful match by grok will result in the
  # filter being finished. If you want grok to try all patterns (maybe you are
  # parsing different things), then set this to false.
  config :break_on_match, :validate => :boolean, :default => true

  # If true, only store named captures from grok.
  config :named_captures_only, :validate => :boolean, :default => true

  # If true, keep empty captures as event fields.
  config :keep_empty_captures, :validate => :boolean, :default => false

  # If true, make single-value fields simply that value, not an array
  # containing that one value.
  config :singles, :validate => :boolean, :default => false

  # If true, ensure the '_grokparsefailure' tag is present when there has been no
  # successful match
  config :tag_on_failure, :validate => :array, :default => ["_grokparsefailure"]

  # TODO(sissel): Add this feature?
  # When disabled, any pattern that matches the entire string will not be set.
  # This is useful if you have named patterns like COMBINEDAPACHELOG that will
  # match entire events and you really don't want to add a field
  # `COMBINEDAPACHELOG` that is set to the whole event line.
  #config :capture_full_match_patterns, :validate => :boolean, :default => false

  # Detect if we are running from a jarfile, pick the right path.
  @@patterns_path ||= Set.new
  if __FILE__ =~ /file:\/.*\.jar!.*/
    @@patterns_path += ["#{File.dirname(__FILE__)}/../../patterns/*"]
  else
    @@patterns_path += ["#{File.dirname(__FILE__)}/../../../patterns/*"]
  end

  public
  def initialize(params)
    super(params)
    @match["@message"] ||= []
    @match["@message"] += @pattern if @pattern # the config 'pattern' value (array)
  end

  public
  def register
    require "grok-pure" # rubygem 'jls-grok'

    @patternfiles = []

    # Have @@patterns_path show first. Last-in pattern definitions win; this
    # will let folks redefine built-in patterns at runtime.
    @patterns_dir = @@patterns_path.to_a + @patterns_dir
    @logger.info? and @logger.info("Grok patterns path", :patterns_dir => @patterns_dir)
    @patterns_dir.each do |path|
      # Can't read relative paths from jars, try to normalize away '../'
      while path =~ /file:\/.*\.jar!.*\/\.\.\//
        # replace /foo/bar/../baz => /foo/baz
        path = path.gsub(/[^\/]+\/\.\.\//, "")
        @logger.debug? and @logger.debug("In-jar path to read", :path => path)
      end

      if File.directory?(path)
        path = File.join(path, "*")
      end

      Dir.glob(path).each do |file|
        @logger.info? and @logger.info("Grok loading patterns from file", :path => file)
        @patternfiles << file
      end
    end

    @patterns = Hash.new { |h,k| h[k] = [] }

    @logger.info? and @logger.info("Match data", :match => @match)

    @match.each do |field, patterns|
      patterns = [patterns] if patterns.is_a?(String)

      if !@patterns.include?(field)
        @patterns[field] = Grok::Pile.new
        #@patterns[field].logger = @logger

        add_patterns_from_files(@patternfiles, @patterns[field])
      end
      @logger.info? and @logger.info("Grok compile", :field => field, :patterns => patterns)
      patterns.each do |pattern|
        @logger.debug? and @logger.debug("regexp: #{@type}/#{field}", :pattern => pattern)
        @patterns[field].compile(pattern)
      end
    end # @config.each
  end # def register

  public
  def filter(event)
    return unless filter?(event)

    # parse it with grok
    matched = false

    @logger.debug? and @logger.debug("Running grok filter", :event => event);
    done = false
    @patterns.each do |field, pile|
      break if done
      if !event[field]
        @logger.debug? and @logger.debug("Skipping match object, field not present", 
                                         :field => field, :event => event)
        next
      end

      @logger.debug? and @logger.debug("Trying pattern", :pile => pile, :field => field)
      (event[field].is_a?(Array) ? event[field] : [event[field]]).each do |fieldvalue|
        begin
          # Coerce all field values to string. This turns arrays, hashes, numbers, etc
          # into strings for grokking. Seems like the best 'do what I mean' thing to do.
          grok, match = pile.match(fieldvalue.to_s)
        rescue Exception => e
          fieldvalue_bytes = []
          fieldvalue.to_s.bytes.each { |b| fieldvalue_bytes << b }
          @logger.warn("Grok regexp threw exception", :exception => e.message,
                       :field => field, :grok_pile => pile,
                       :fieldvalue_bytes => fieldvalue_bytes)
        end
        next unless match
        matched = true
        done = true if @break_on_match

        match.each_capture do |key, value|
          type_coerce = nil
          is_named = false
          if key.include?(":")
            name, key, type_coerce = key.split(":")
            is_named = true
          end

          # http://code.google.com/p/logstash/issues/detail?id=45
          # Permit typing of captures by giving an additional colon and a type,
          # like: %{FOO:name:int} for int coercion.
          if type_coerce
            @logger.info? and @logger.info("Match type coerce: #{type_coerce}")
            @logger.info? and @logger.info("Patt: #{grok.pattern}")
          end

          case type_coerce
            when "int"
              value = value.to_i
            when "float"
              value = value.to_f
          end

          # Special casing to skip captures that represent the entire log message.
          if fieldvalue == value and field == "@message" and key.nil?
            # Skip patterns that match the entire message
            @logger.debug? and @logger.debug("Skipping capture since it matches the whole line.", :field => key)
            next
          end

          if @named_captures_only && !is_named
            @logger.debug? and @logger.debug("Skipping capture since it is not a named " "capture and named_captures_only is true.", :field => key)
            next
          end

          if event.fields[key].is_a?(String)
            event.fields[key] = [event.fields[key]]
          end

          if @keep_empty_captures && event.fields[key].nil?
            event.fields[key] = []
          end

          # If value is not nil, or responds to empty and is not empty, add the
          # value to the event.
          if !value.nil? && (!value.empty? rescue true)
            # Store fields as an array unless otherwise instructed with the
            # 'singles' config option
            if !event.fields.include?(key) and @singles
              event.fields[key] = value
            else
              event.fields[key] ||= []
              event.fields[key] << value
            end
          end
        end # match.each_capture

        filter_matched(event)
      end # event[field]
    end # patterns.each

    if !matched
      # Tag this event if we can't parse it. We can use this later to
      # reparse+reindex logs if we improve the patterns given .
      @tag_on_failure.each do |tag|
        event.tags << tag unless event.tags.include?(tag)
      end
    end

    @logger.debug? and @logger.debug("Event now: ", :event => event)
  end # def filter

  private
  def add_patterns_from_files(paths, pile)
    paths.each { |path| add_patterns_from_file(path, pile) }
  end

  private
  def add_patterns_from_file(path, pile)
    # Check if the file path is a jar, if so, we'll have to read it ourselves
    # since libgrok won't know what to do with it.
    if path =~ /file:\/.*\.jar!.*/
      File.new(path).each do |line|
        next if line =~ /^(?:\s*#|\s*$)/
        # In some cases I have seen 'file.each' yield lines with newlines at
        # the end. I don't know if this is a bug or intentional, but we need
        # to chomp it.
        name, pattern = line.chomp.split(/\s+/, 2)
        @logger.debug? and @logger.debug("Adding pattern from file", :name => name,
                                         :pattern => pattern, :path => path)
        pile.add_pattern(name, pattern)
      end
    else
      pile.add_patterns_from_file(path)
    end
  end # def add_patterns
end # class LogStash::Filters::Grok
