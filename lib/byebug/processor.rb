require 'forwardable'
require_relative 'interface'
require_relative 'command'

module Byebug

  # Should this be a mixin?
  class Processor
    attr_accessor :interface

    extend Forwardable
    def_delegators :@interface, :errmsg, :print, :aprint, :afmt

    def initialize(interface)
      @interface = interface
    end
  end

  class CommandProcessor < Processor
    attr_reader :display

    @@Show_breakpoints_postcmd = [ Byebug::BreakCommand.new(nil).regexp,
                                   Byebug::ConditionCommand.new(nil).regexp,
                                   Byebug::DeleteCommand.new(nil).regexp,
                                   Byebug::DisableCommand.new(nil).regexp,
                                   Byebug::EnableCommand.new(nil).regexp
                                 ]
    @@Show_annotations_run = [ Byebug::ContinueCommand.new(nil).regexp,
                               Byebug::FinishCommand.new(nil).regexp,
                               Byebug::NextCommand.new(nil).regexp,
                               Byebug::StepCommand.new(nil).regexp
                             ]
    @@Show_annotations_postcmd = [ Byebug::DownCommand.new(nil).regexp,
                                   Byebug::FrameCommand.new(nil).regexp,
                                   Byebug::UpCommand.new(nil).regexp
                                 ]

    def initialize(interface = LocalInterface.new)
      super(interface)

      @display = []
      @mutex = Mutex.new
      @last_cmd               = nil   # To allow empty (just <RET>) commands
      @last_file              = nil   # Filename the last time we stopped
      @last_line              = nil   # Line number the last time we stopped
      @breakpoints_were_empty = false # Show breakpoints 1st time
      @displays_were_empty    = true  # No display 1st time
      @context_was_dead       = false  # Assume we haven't started.
    end

    def interface=(interface)
      @mutex.synchronize do
        @interface.close if @interface
        @interface = interface
      end
    end

    require 'pathname'  # For cleanpath

    ##
    # Regularize file name.
    #
    # This is also used as a common funnel place if basename is desired or if we
    # are working remotely and want to change the basename. Or we are eliding
    # filenames.
    def self.canonic_file(filename)
      return '(nil)' if not filename

      # For now we want resolved filenames
      if Command.settings[:basename]
        File.basename(filename)
      else
        # Cache this?
        Pathname.new(filename).cleanpath.to_s
      end
    end

    def self.protect(mname)
      alias_method "__#{mname}", mname
      module_eval %{
        def #{mname}(*args)
          @mutex.synchronize do
            return unless @interface
            __#{mname}(*args)
          end
        rescue IOError, Errno::EPIPE
          self.interface = nil
        rescue SignalException
          raise
        rescue Exception
          print "INTERNAL ERROR!!! #\{$!\}\n" rescue nil
          print $!.backtrace.map{|l| "\t#\{l\}"}.join("\n") rescue nil
        end
      }
    end

    def at_breakpoint(context, breakpoint)
      aprint 'stopped'
      n = Byebug.breakpoints.index(breakpoint) + 1
      file = CommandProcessor.canonic_file(breakpoint.source)
      line = breakpoint.pos
      aprint "source #{file}:#{line}"
      print "Stopped by breakpoint #{n} at #{file}:#{line}\n"
    end
    protect :at_breakpoint

    def at_catchpoint(context, excpt)
      aprint 'stopped'
      file = CommandProcessor.canonic_file(context.frame_file(0))
      line = context.frame_line(0)
      print "Catchpoint at %s:%d: `%s' (%s)\n", file, line, excpt, excpt.class
      fs = context.stack_size
      tb = caller(0)[-fs..-1]
      if tb
        for i in tb
          print "\tfrom %s\n", i
        end
      end
    end
    protect :at_catchpoint

    def at_tracing(context, file, line)
      if file != @last_file || line != @last_line ||
         Command.settings[:tracing_plus] == false
        @last_file = file
        @last_line = line
        print "Tracing: #{CommandProcessor.canonic_file(file)}:#{line} " \
              "#{Byebug.line_at(file,line)}\n"
      end
      always_run(context, file, line, 2)
    end
    protect :at_tracing

    def at_line(context, file, line)
      process_commands(context, file, line)
    end
    protect :at_line

    def at_return(context, file, line)
      process_commands(context, file, line)
    end
    protect :at_return

    private
      ##
      # Prompt shown before reading a command.
      #
      def prompt(context)
        p = "(byebug#{context.dead?  ? ':post-mortem' : ''}) "
        p = afmt("pre-prompt")+p+"\n"+afmt("prompt") if Byebug.annotate.to_i > 2
        return p
      end

      ##
      # Run commands everytime.
      #
      # For example display commands or possibly the list or irb in an
      # "autolist" or "autoirb".
      #
      # @return List of commands acceptable to run bound to the current state
      #
      def always_run(context, file, line, run_level)
        event_cmds = Command.commands.select{|cmd| cmd.event }

        # Remove some commands in post-mortem
        event_cmds = event_cmds.find_all do |cmd|
          cmd.allow_in_post_mortem
        end if context.dead?

        state = State.new(event_cmds, context, @display, file, @interface, line)

        # Change default when in irb or code included in command line
        Command.settings[:autolist] = 0 if file == '(irb)' or file == '-e'

        # Bind commands to the current state.
        commands = event_cmds.map{|cmd| cmd.new(state)}

        commands.select do |cmd|
          cmd.class.always_run >= run_level
        end.each {|cmd| cmd.execute}
        return state, commands
      end

      ##
      # Splits a command line of the form "cmd1 ; cmd2 ; ... ; cmdN" into an
      # array of commands: [cmd1, cmd2, ..., cmdN]
      #
      def split_commands(cmd_line)
        cmd_line.split(/;/).inject([]) do |m, v|
          if m.empty?
            m << v
          else
            if m.last[-1] == ?\\
              m.last[-1,1] = ''
              m.last << ';' << v
            else
              m << v
            end
          end
          m
        end
      end

      ##
      # Handle byebug commands.
      #
      def process_commands(context, file, line)
        state, commands = always_run(context, file, line, 1)
        $state = Command.settings[:testing] ? state : nil

        preloop(commands, context)
        aprint state.location if Command.settings[:autolist] == 0

        while !state.proceed?
          input = @interface.command_queue.empty? ?
                  @interface.read_command(prompt(context)) :
                  @interface.command_queue.shift
          break unless input
          catch(:debug_error) do
            if input == ""
              next unless @last_cmd
              input = @last_cmd
            else
              @last_cmd = input
            end
            split_commands(input).each do |cmd|
              one_cmd(commands, context, cmd)
              postcmd(commands, context, cmd)
            end
          end
        end
        postloop(commands, context)
      end

      ##
      # Executes a single byebug command
      #
      def one_cmd(commands, context, input)
        if cmd = commands.find{ |c| c.match(input) }
          if context.dead? && cmd.class.need_context
            print "Command is unavailable\n"
          else
            cmd.execute
          end
        else
          unknown_cmd = commands.find{ |c| c.class.unknown }
          if unknown_cmd
            unknown_cmd.execute
          else
            errmsg "Unknown command: \"#{input}\".  Try \"help\".\n"
          end
        end
      end

      def preloop(commands, context)
        @context_was_dead = true if context.dead? and not @context_was_dead

        aprint 'stopped'
        if @context_was_dead
          aprint 'exited'
          print "The program finished.\n"
          @context_was_dead = false
        end

        if Byebug.annotate.to_i > 2
          breakpoint_annotations(commands, context)
          display_annotations(commands, context)
          annotation('stack', commands, context, "where")
          annotation('variables', commands, context, "info variables") unless
            context.dead?
        end
      end

      def postcmd(commands, context, cmd)
        if Byebug.annotate.to_i > 2
          cmd = @last_cmd unless cmd
          breakpoint_annotations(commands, context) if
            @@Show_breakpoints_postcmd.find{|pat| cmd =~ pat}
          display_annotations(commands, context)
          if @@Show_annotations_postcmd.find{|pat| cmd =~ pat}
            annotation('stack', commands, context, "where") if
              context.stack_size > 0
            annotation('variables', commands, context, "info variables") unless
              context.dead?
          end
          if not context.dead? and @@Show_annotations_run.find{|pat| cmd =~ pat}
            afmt 'starting'
            @context_was_dead = false
          end
        end
      end

      def postloop(commands, context)
      end

      def annotation(label, commands, context, cmd)
        print afmt(label)
        one_cmd(commands, context, cmd)
      end

      def breakpoint_annotations(commands, context)
        unless Byebug.breakpoints.empty? and @breakpoints_were_empty
          annotation('breakpoints', commands, context, "info breakpoints")
          @breakpoints_were_empty = Byebug.breakpoints.empty?
        end
      end

      def display_annotations(commands, context)
        return if display.empty?
        have_display = display.find{|d| d[0]}
        return unless have_display and @displays_were_empty
        @displays_were_empty = have_display
        annotation('display', commands, context, "display")
      end

      class State
        attr_accessor :commands, :context, :display, :file, :frame_pos
        attr_accessor :interface, :line, :previous_line

        def initialize(commands, context, display, file, interface, line)
          @commands, @context, @display = commands, context, display
          @file, @interface, @line = file, interface, line
          @frame_pos, @previous_line, @proceed = 0, nil, false
        end

        extend Forwardable
        def_delegators :@interface, :aprint, :errmsg, :print, :confirm

        def proceed?
          @proceed
        end

        def proceed
          @proceed = true
        end

        def location
          loc = "#{CommandProcessor.canonic_file(@file)} @ #{@line}\n"
          loc += "#{Byebug.line_at(@file, @line)}\n" unless
            ['(irb)', '-e'].include? @file
        end
      end

  end # class CommandProcessor


  class ControlCommandProcessor < Processor

    def initialize(interface)
      super(interface)
      @context_was_dead = false # Assume we haven't started.
    end

    def process_commands(verbose=false)
      control_cmds = Command.commands.select do |cmd|
        cmd.allow_in_control
      end
      state = State.new(@interface, control_cmds)
      commands = control_cmds.map{|cmd| cmd.new(state) }

      if @context_was_dead
        aprint 'exited'
        print "The program finished.\n"
        @context_was_dead = false
      end

      while input = @interface.read_command(prompt(nil))
        print "+#{input}" if verbose
        catch(:debug_error) do
          if cmd = commands.find{|c| c.match(input) }
            cmd.execute
          else
            errmsg "Unknown command\n"
          end
        end
      end
    rescue IOError, Errno::EPIPE
    rescue Exception
      print "INTERNAL ERROR!!! #{$!}\n" rescue nil
      print $!.backtrace.map{|l| "\t#{l}"}.join("\n") rescue nil
    ensure
      @interface.close
    end

    # The prompt shown before reading a command.
    # Note: have an unused 'context' parameter to match the local interface.
    def prompt(context)
      p = '(byebug:ctrl) '
      p = afmt("pre-prompt") +p+"\n"+ afmt("prompt") if Byebug.annotate.to_i > 2
      return p
    end

    class State
      attr_reader :commands, :interface

      def initialize(interface, commands)
        @interface = interface
        @commands = commands
      end

      def proceed
      end

      extend Forwardable
      def_delegators :@interface, :errmsg, :print

      def confirm(*args)
        'y'
      end

      def context
        nil
      end

      def file
        errmsg "No filename given.\n"
        throw :debug_error
      end
    end
  end
end
