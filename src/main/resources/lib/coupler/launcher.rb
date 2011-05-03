require 'java'
require 'rbconfig'
require 'date'
require 'uri'
require 'digest/md5'
require 'fileutils'
require 'net/http'
require 'net/https'
require 'pp'

module Coupler
  class Launcher
    include java.lang.Runnable
    include_package 'java.awt'

    FILES_URL = "http://biostat.mc.vanderbilt.edu/coupler/"
    TEXT_X = 130
    TEXT_Y = 200
    TEXT_W = 260
    PROGRESS_X = TEXT_X
    PROGRESS_Y = TEXT_Y + 10
    PROGRESS_W = TEXT_W
    PROGRESS_H = 25

    def setup_gui
      @splash = SplashScreen.splash_screen
      bounds = @splash.bounds

      @graphic = @splash.create_graphics
      @graphic.composite = AlphaComposite::Clear
      @graphic.set_paint_mode
      font = Font.new("Lucida Sans", 0, 16)
      @graphic.font = font
      @font_metrics = @graphic.font_metrics
    end

    def print_update(string)
      width = @font_metrics.string_width(string)
      @graphic.color = Color::WHITE
      @graphic.fill_rect(TEXT_X, TEXT_Y - 30, TEXT_W, 60)
      @graphic.color = Color::BLACK
      @graphic.draw_string(string, TEXT_X + (TEXT_W - width) / 2, TEXT_Y)
      @splash.update
    end

    def find_coupler_dir
      print_update("Locating Coupler directory...")

      @coupler_dir =
        case Config::CONFIG['host_os']
        when /mswin|windows/i
          # Windows
          File.join(ENV['APPDATA'], "coupler")
        else
          if ENV['HOME']
            File.join(ENV['HOME'], ".coupler")
          else
            # FIXME: ask the user
            raise "Can't figure out where Coupler lives"
          end
        end
      @coupler_dir = File.expand_path(@coupler_dir)

      if !File.exist?(@coupler_dir)
        begin
          Dir.mkdir(@coupler_dir)
        rescue Errno::EACCES
          raise "Couldn't create the Coupler directory: #{@coupler_dir}"
        end
      end
      puts "COUPLER DIR: #{@coupler_dir}"
    end

    def find_latest_files
      print_update("Checking for updates...")

      doc = org.jsoup.Jsoup.connect(FILES_URL).get
      elts = doc.select('table tbody tr')
      raise "Can't connect to repository" unless elts.size > 0

      files = {}

      elts.each do |tr|
        tds = tr.select('td')
        file_td = tds.get(0)
        mtime_td = tds.get(1)
        md5_td = tds.get(2)
        link = file_td.select('a').get(0)

        basename = link.html
        name = basename.sub(/-[a-f0-9]{7}\.jar$/, "")
        mtime = Date.parse(mtime_td.html)

        if files[name].nil? || files[name][:mtime] < mtime
          files[name] = {
            :basename => basename,
            :mtime => mtime,
            :href => link.attr('href'),
            :md5 => md5_td.html
          }
        end
      end

      puts "=== LATEST FILES ==="
      pp files

      @latest_files = files
    end

    def setup_progress_bar
      x, y, w, h = PROGRESS_X, PROGRESS_Y, PROGRESS_W, PROGRESS_H
      #puts "Setup: #{[x, y, w, h].inspect}"
      @graphic.color = Color::BLACK
      @graphic.draw(Rectangle.new(x, y, w, h))
      @splash.update
    end

    def nudge_progress_bar(size, total)
      x, y, w, h = PROGRESS_X, PROGRESS_Y, PROGRESS_W, PROGRESS_H
      w = (w * (size.to_f / total.to_f)).round
      #puts "Size: #{size}; Total: #{total}; Nudge: #{[x, y, w, h].inspect}"
      @graphic.color = Color::BLUE
      @graphic.fill_rect(x, y, w, h)
      @splash.update
    end

    def remove_progress_bar
      x, y, w, h = PROGRESS_X-5, PROGRESS_Y-5, PROGRESS_W+10, PROGRESS_H+10
      @graphic.color = Color::WHITE
      @graphic.fill_rect(x, y, w, h)
      @splash.update
    end

    def download_file(name, url, local)
      puts "DOWNLOADING: #{url}"
      print_update("Downloading #{name}...")
      http = Net::HTTP.new(url.host, url.port)
      http.request_get(url.path) do |response|
        setup_progress_bar
        out = File.open(local, 'wb')
        total_size = response['content-length']
        size = 0
        response.read_body do |segment|
          size += segment.length
          nudge_progress_bar(size, total_size)
          out.write(segment)
        end
        out.flush
        out.close
        remove_progress_bar
      end
      puts "DOWNLOADED: #{name} => #{local}"
    end

    def update_installation
      files_url = URI.parse(FILES_URL)
      @installed_files = {}
      puts "=== VERIFY FILES ==="
      @latest_files.each_pair do |name, info|
        shortname = name.split(/-/)[-1]
        print_update("Verifying #{shortname}...")

        get_file = true
        local_fn = File.join(@coupler_dir, info[:basename])
        if File.exist?(local_fn)
          md5 = Digest::MD5.hexdigest(File.open(local_fn, 'rb') { |f| f.read })
          puts "Local MD5:  #{md5.inspect}"
          puts "Remote MD5: #{info[:md5].inspect}"
          if md5 != info[:md5]
            puts "#{info[:basename]} seems to be corrupt; will redownload it."
          else
            puts "#{info[:basename]} looks good to me!"
            get_file = false
          end
        end

        if get_file
          url = files_url + info[:href]
          download_file(shortname, url, local_fn)
        end
        @installed_files[name] = local_fn
      end

      # unlink old files
      old_files = Dir[File.join(@coupler_dir, "*.jar")] - @installed_files.values
      old_files.each do |fn|
        FileUtils.rm_f(fn)
      end
      puts "INSTALLED FILES: #{@installed_files.inspect}"
    end

    def start_coupler
      tmp = %w{coupler coupler-dependencies} - @installed_files.keys
      if !tmp.empty?
        print_update("Missing #{tmp.join(' and ')} runtime files. Quitting...")
        sleep 2
        return false
      end

      # This involves some skullduggery.
      dependency_jar = @installed_files['coupler-dependencies']
      Gem.use_paths(nil, ["file:#{dependency_jar}!/"])
      require dependency_jar  # for java stuff
      require "file:#{@installed_files['coupler']}!/lib/coupler"

      if !Coupler::Server.instance.is_running?
        print_update("Starting database...")
        @stop_server = true
        Server.instance.start
      end

      print_update("Migrating database...")
      Coupler::Database.instance.migrate!

      if !Coupler::Scheduler.instance.is_started?
        print_update("Starting scheduler...")
        @stop_scheduler = true
        Coupler::Scheduler.instance.start
      end

      print_update("Starting web server...")
      handler = Rack::Handler.get('mongrel')
      settings = Coupler::Base.settings

      # See the Rack::Handler::Mongrel.run! method
      # NOTE: I don't want to join the server, which is why I'm doing this
      #       by hand.
      @web_server = Mongrel::HttpServer.new(settings.bind, settings.port, 950, 0, 60)
      @web_server.register('/', handler.new(Coupler::Base))
      @web_thread = @web_server.run
      Coupler::Base.set(:running, true)

      true
    end

    def launch_browser
      print_update("Launching browser...")

      if !Desktop.desktop_supported?
        # FIXME: don't just return.
        puts "Can't open browser. Desktop not supported :("
        puts "Please go to http://localhost:4567 manually"
        return
      end

      desktop = Desktop.desktop
      if !desktop.supported?(Desktop::Action::BROWSE)
        # FIXME: don't just return.
        puts "Can't open browser. Desktop browse not supported :("
        puts "Please go to http://localhost:4567 manually"
        return
      end

      uri = java.net.URI.new("http://localhost:4567/")
      desktop.browse(uri.java_object)
    end

    def setup_tray_icon
      if !SystemTray.supported?
        puts "Can't open system tray :("
        trap("INT") do
          shutdown
        end
        @web_thread.join

        return
      end

      # get the SystemTray instance
      @tray = SystemTray.system_tray

      # load an image
      icon_size = @tray.tray_icon_size
      w = icon_size.width
      h = icon_size.height
      scale = false
      if w == h && (w == 64 || w == 48 || w == 32 || w == 24 || w == 16)
        icon = "tray_icon-#{w}x#{h}.png"
      else
        scale = true
        icon = "tray_icon.png"
      end
      url = java.net.URL.new("jar:" + File.dirname(__FILE__).sub(/!\/.+$/, "!/") + icon)
      image = Toolkit.default_toolkit.get_image(url)
      if scale
        image = image.getScaledInstance(icon_size.width, icon_size.height, 1)
      end

      # create a popup menu
      popup = PopupMenu.new

      # create menu item for the default action
      default_item = MenuItem.new("Quit")
      default_item.add_action_listener do |e|
        shutdown
      end
      popup.add(default_item)

      # construct a TrayIcon
      @tray_icon = TrayIcon.new(image, "Coupler", popup)
      # set the TrayIcon properties
      #trayIcon.addActionListener do |e|
      #end

      # add the tray image
      begin
        @tray.add(@tray_icon)
      rescue AWTException => e
        puts(e)
      end
    end

    def shutdown
      if @stop_scheduler
        Coupler::Scheduler.instance.shutdown
      end

      if @stop_server
        Coupler::Server.instance.shutdown
      end

      @web_server.stop

      if @tray
        @tray.remove(@tray_icon)
      end
    end

    def run
      setup_gui
      find_coupler_dir
      find_latest_files
      update_installation
      if start_coupler
        launch_browser
        @splash.close

        setup_tray_icon
      end
    end
  end
end
