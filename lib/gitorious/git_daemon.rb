require 'daemons'
require 'geoip'
require 'socket'
require 'fcntl'

ActiveRecord::Base.allow_concurrency = true

ENV["PATH"] = "/usr/local/bin/:/opt/local/bin:#{ENV["PATH"]}"

BASE_PATH = File.expand_path(GitoriousConfig['repository_base_path'])

TIMEOUT = 30
MAX_CHILDREN = 30
$children_reaped = 0
$children_active = 0

class GeoIP
  def close
    @file.close
  end
end

module Git
  class Daemon
    include Daemonize

    SERVICE_READ_REGEXP = /^(git\-upload\-pack|git\ upload\-pack)\s(.+)\x00host=([\w\.\-]+)/.freeze
    SERVICE_WRITE_REGEXP = /^(git\-receive\-pack|git\ receive\-pack)\s(.+)\x00host=([\w\.\-]+)/.freeze

    def initialize(options)
      @options = options
    end

    def start
      if @options[:daemonize]
        daemonize(@options[:logfile])
      end
      Dir.chdir(Rails.root) # So Logger don't get confused
      @socket = TCPServer.new(@options[:host], @options[:port])
      @socket.setsockopt(Socket::SOL_SOCKET,Socket::SO_REUSEADDR, !!@options[:reuseaddr])
      @socket.fcntl(Fcntl::F_SETFD, Fcntl::FD_CLOEXEC)
      log(Process.pid, "Listening on #{@options[:host]}:#{@options[:port]}...")
      ActiveRecord::Base.verify_active_connections! if @options[:daemonize]
      run
    end

    def run
      Dir.chdir(GitoriousConfig["repository_base_path"])
      if @options[:pidfile]
        File.open(@options[:pidfile], "w") do |f|
          f.write(Process.pid)
        end
      end
      while session = accept_socket
        connections = $children_active - $children_reaped
        if connections > MAX_CHILDREN
          log(Process.pid, "too many active children #{connections}/#{MAX_CHILDREN}")
          session.close
          next
        end

        if defined?JRUBY_VERSION
          Thread.new {
            run_service(session)
          }.run
        else
            run_service(session)
        end
      end
    end

    def run_service(session)
      $children_active += 1
      ip_family, port, name, ip = session.peeraddr

      line = receive_data(session)

      if line =~ SERVICE_READ_REGEXP
        start_time = Time.now
        service = $1
        base_path = $2
        host = $3

        path = File.expand_path("#{BASE_PATH}/#{base_path}")
        log(Process.pid, "Connection from #{ip} for #{base_path.inspect}")

        repository = nil
        begin
          ActiveRecord::Base.verify_active_connections!
          repository = ::Repository.find_by_path(path)
        rescue => e
          log(Process.pid, "AR error: #{e.class.name} #{e.message}:\n #{e.backtrace.join("\n  ")}")
        end

        unless repository
          log(Process.pid, "Cannot find repository: #{path}")
          write_error_message(session, "Cannot find repository: #{base_path}")
          $children_active -= 1
          session.close
          return
        end

        real_path = File.expand_path(repository.full_repository_path)
        log(Process.pid, "#{ip} wants #{path.inspect} => #{real_path.inspect}")

        if real_path.index(BASE_PATH) != 0 || !File.directory?(real_path)
          log(Process.pid, "Invalid path: #{real_path}")
          write_error_message(session, "Cannot find repository: #{base_path}")
          session.close
          $children_active -= 1
          return
        end

        if !File.exist?(File.join(real_path, "git-daemon-export-ok"))
          session.close
          $children_active -= 1
          return
        end

        unless @options[:disable_geoip]
          if ip_family == "AF_INET6"
            repository.cloned_from(ip)
          else
            geoip = GeoIP.new(File.join(RAILS_ROOT, "data", "GeoIP.dat"))
            localization = geoip.country(ip)
            geoip.close
            repository.cloned_from(ip, localization[3], localization[5], 'git')
          end
        end

        Dir.chdir(real_path) do
          cmd = "git-upload-pack --strict --timeout=#{TIMEOUT} ."

          if defined?JRUBY_VERSION
            git_pipe = IO.popen(cmd, 'r+')

            s = StringIO.new
            while (data = git_pipe.read(1))
              s << data
              break if s.string =~ /0000$/
            end
            session.write(s.string)
            s = StringIO.new
            while (data = session.read(1))
              s << data
              break if s.string =~ /done$/
            end
            git_pipe.puts(s.string)
            git_pipe.flush
            while (data = git_pipe.read(1))
              session.write(data)
            end
            git_pipe.close
          else
            child_pid = fork do
              log(Process.pid, "Deferred in #{'%0.5f' % (Time.now - start_time)}s")

              $stdout.reopen(session)
              $stdin.reopen(session)
              $stderr.reopen("/dev/null")

              exec(cmd)
              # FIXME; we don't ever get here since we exec(), so reaped count may be incorrect
              $children_reaped += 1
              exit!
            end
          end
        end rescue Errno::EAGAIN
      elsif line =~ SERVICE_WRITE_REGEXP
        service, base_path, host = $1, $2, $3
        log(Process.pid, "Not accepting #{service.inspect} for #{base_path.inspect}")
        write_error_message(session, "The git:// url is read-only. Please see " +
          "#{GitoriousConfig['scheme']}://#{GitoriousConfig['gitorious_host']}#{base_path.sub(/\.git$/, '')} " +
          "for the push url, if you're a committer.")
        $children_active -= 1
        session.close
        return
      else
        # $stderr.puts "Invalid request from #{ip}: #{line.inspect}"
        $children_active -= 1
      end
      session.close
    end

    def handle_stop(signal)
      @socket.close
      log(Process.pid, "Received #{signal}, exiting..")
      exit 0
    end

    def handle_cld
      loop do
        pid = nil
        begin
          pid = Process.wait(-1, Process::WNOHANG)
        rescue Errno::ECHILD
          break
        end

        if pid && $?
          $children_reaped += 1
          log(pid, "Disconnected. (status=#{$?.exitstatus})") if pid > 0
          if $children_reaped == $children_active
            $children_reaped = 0
            $children_active = 0
          end

          next
        end
        break
      end
    end

    def log(pid, msg)
      $stderr.puts "#{Time.now.strftime("%Y-%m-%d %H:%M:%S")} [#{pid}] #{msg}"
    end

    def write_error_message(session, msg)
      message = ["\n----------------------------------------------"]
      message << msg
      message << "----------------------------------------------\n"
      write_into_sideband(session, message.join("\n"), 2)
    end

    def write_into_sideband(session, message, channel)
      msg = "%s%s" % [channel.chr, message]
      session.write("%04x%s" % [msg.length+4, msg])
    end

    def accept_socket
      if RUBY_VERSION < '1.9'
        @socket.accept
      else
        begin
          @socket.accept_nonblock
        rescue Errno::EAGAIN, Errno::EWOULDBLOCK, Errno::ECONNABORTED, Errno::EPROTO, Errno::EINTR => e
          if IO.select([@socket])
            retry
          else
            raise e
          end
        end
      end
    end

    def receive_data(session)
      if RUBY_VERSION < '1.9'
        read_data(session)
      else
        read_data_nonblock(session)
      end
    end

    def read_data(session)
      size_string = session.recv(4)
      return "" if !size_string
      size = size_string.to_i(16)
      return "" unless size > 4
      session.recv(size - 4)
    rescue Errno::ECONNRESET
      return ""
    end

    def read_data_nonblock(session)
      begin
        size_string = session.recv_nonblock(4)
        return "" if !size_string
        size = size_string.to_i(16)
        return "" unless size > 4
        session.recv_nonblock(size - 4)
      rescue Errno::EAGAIN, Errno::EWOULDBLOCK, Errno::ECONNABORTED, Errno::EPROTO, Errno::EINTR
        if IO.select([@socket])
          retry
        else
          return ""
        end
      end
    end

  end
end
