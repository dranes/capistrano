require 'capistrano/command'

module Capistrano
  class Configuration
    module Actions
      module Invocation
        def self.included(base) #:nodoc:
          base.extend(ClassMethods)

          base.send :alias_method, :initialize_without_invocation, :initialize
          base.send :alias_method, :initialize, :initialize_with_invocation

          base.default_io_proc = Proc.new do |ch, stream, out|
            level = stream == :err ? :important : :info
            ch[:options][:logger].send(level, out, "#{stream} :: #{ch[:server]}")
          end
        end

        module ClassMethods
          attr_accessor :default_io_proc
        end

        def initialize_with_invocation(*args) #:nodoc:
          initialize_without_invocation(*args)
          set :default_environment, {}
          set :default_run_options, {}
        end

        # Invokes the given command. If a +via+ key is given, it will be used
        # to determine what method to use to invoke the command. It defaults
        # to :run, but may be :sudo, or any other method that conforms to the
        # same interface as run and sudo.
        def invoke_command(cmd, options={}, &block)
          options = options.dup
          via = options.delete(:via) || :run
          send(via, cmd, options, &block)
        end

        # Execute the given command on all servers that are the target of the
        # current task. If a block is given, it is invoked for all output
        # generated by the command, and should accept three parameters: the SSH
        # channel (which may be used to send data back to the remote process),
        # the stream identifier (<tt>:err</tt> for stderr, and <tt>:out</tt> for
        # stdout), and the data that was received.
        def run(cmd, options={}, &block)
          block ||= self.class.default_io_proc
          logger.debug "executing #{cmd.strip.inspect}"

          options = add_default_command_options(options)

          execute_on_servers(options) do |servers|
            targets = servers.map { |s| sessions[s] }
            Command.process(cmd, targets, options.merge(:logger => logger), &block)
          end
        end

        # Like #run, but executes the command via <tt>sudo</tt>. This assumes
        # that the sudo password (if required) is the same as the password for
        # logging in to the server.
        #
        # Also, this module accepts a <tt>:sudo</tt> configuration variable,
        # which (if specified) will be used as the full path to the sudo
        # executable on the remote machine:
        #
        #   set :sudo, "/opt/local/bin/sudo"
        def sudo(command, options={}, &block)
          block ||= self.class.default_io_proc

          options = options.dup
          as = options.delete(:as)

          user = as && "-u #{as}"
          command = [fetch(:sudo, "sudo"), "-p '#{sudo_prompt}'", user, command].compact.join(" ")

          run(command, options, &sudo_behavior_callback(block))
        end

        # Returns a Proc object that defines the behavior of the sudo
        # callback. The returned Proc will defer to the +fallback+ argument
        # (which should also be a Proc) for any output it does not
        # explicitly handle.
        def sudo_behavior_callback(fallback) #:nodoc:
          # in order to prevent _each host_ from prompting when the password
          # was wrong, let's track which host prompted first and only allow
          # subsequent prompts from that host.
          prompt_host = nil

          Proc.new do |ch, stream, out|
            if out =~ /^#{Regexp.escape(sudo_prompt)}/
              ch.send_data "#{self[:password]}\n"
            elsif out =~ /try again/
              if prompt_host.nil? || prompt_host == ch[:server]
                prompt_host = ch[:server]
                logger.important out, "#{stream} :: #{ch[:server]}"
                reset! :password
              end
            else
              fallback.call(ch, stream, out)
            end
          end
        end

        # Merges the various default command options into the options hash and
        # returns the result. The default command options that are understand
        # are:
        #
        # * :default_environment: If the :env key already exists, the :env
        #   key is merged into default_environment and then added back into
        #   options.
        # * :default_shell: if the :shell key already exists, it will be used.
        #   Otherwise, if the :default_shell key exists in the configuration,
        #   it will be used. Otherwise, no :shell key is added.
        def add_default_command_options(options)
          defaults = self[:default_run_options]
          options = defaults.merge(options)

          env = self[:default_environment]
          env = env.merge(options[:env]) if options[:env]
          options[:env] = env unless env.empty?

          shell = options[:shell] || self[:default_shell]
          options[:shell] = shell if shell

          options
        end

        private

          # Returns the prompt text to use with sudo
          def sudo_prompt
            fetch(:sudo_prompt, "sudo password: ")
          end
      end
    end
  end
end