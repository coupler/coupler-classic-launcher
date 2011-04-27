require 'java'
require 'rbconfig'
require 'date'
require 'uri'
require 'open-uri'
require 'digest/md5'
require 'fileutils'
require 'net/http'
require 'net/https'

module Coupler
  class Launcher
    include java.lang.Runnable
    include_package 'java.awt'

    GITHUB_URL = "https://github.com/coupler/coupler/downloads"
    TEXT_X = 120
    TEXT_Y = 200
    TEXT_W = 280

    def setup_gui
      @splash = SplashScreen.splash_screen
      bounds = @splash.bounds

      @graphic = @splash.create_graphics
      @graphic.composite = AlphaComposite::Clear
      @graphic.set_paint_mode
      font = Font.new("Verdana", 0, 16)
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
    end

    def find_latest_files
      print_update("Checking for updates...")

      doc = org.jsoup.Jsoup.connect(GITHUB_URL).get
      elts = doc.select('ol#manual_downloads')
      if elts.size == 0
        raise "Can't connect to github"
      end
      ol = elts.get(0)

      files = {}

      ol.select('li').each do |li|
        links = li.select('h4 a')
        next  if links.size == 0
        link = links.get(0)

        abbrs = li.select('abbr')
        next  if abbrs.size == 0

        abbr = abbrs.get(0)
        date = Date.parse(abbr.html)
        basename = link.html
        name = basename.sub(/-[a-f0-9]+\.jar$/, "")
        if files[name].nil? || files[name][:date] < date
          files[name] = {
            :basename => basename,
            :date => date,
            :href => link.attr('href')
          }
        end
      end

      @latest_files = files
    end

    def follow_redirection_for(url)
      found = false
      etag = nil
      until found
        puts url
        http = Net::HTTP.new(url.host, url.port)
        http.use_ssl = url.scheme == "https"
        http.start
        res = http.request_head(url.path)
        http.finish

        case res.code
        when '302'
          url = url + res.header['location']
        when '200'
          found = true
          etag = res.header['etag']
        else
          raise "Unexpected response when getting JAR: #{res}"
        end
      end
      { :url => url, :etag => etag }
    end

    def update_installation
      github_url = URI.parse(GITHUB_URL)
      @installed_files = {}
      @latest_files.each_pair do |name, info|
        print_update("Verifying #{name}...")

        get_file = true
        rinfo = follow_redirection_for(github_url + info[:href])

        local_fn = File.join(@coupler_dir, info[:basename])
        if File.exist?(local_fn)
          md5 = Digest::MD5.hexdigest(File.read(local_fn))
          if md5 && rinfo[:etag].gsub('"', '') != md5
            puts "#{info[:basename]} seems to be corrupt; will redownload it."
          else
            puts "#{info[:basename]} looks good to me!"
            get_file = false
          end
        end

        if get_file
          print_update("Downloading #{name}...")
          tempfile = open(rinfo[:url])
          tempfile.close
          FileUtils.mv(tempfile.path, local_fn)

          # unlink old files
          Dir[File.join(@coupler_dir, "#{name}*")].each do |fn|
            FileUtils.rm_f(fn)  if fn != local_fn
          end
        end
        @installed_files[name] = local_fn
      end
    end

    def start_coupler
      tmp = %w{coupler coupler-dependencies} - @installed_files.keys
      if !tmp.empty?
        print_update("Missing #{tmp.join(' and ')} runtime files. Quitting...")
        sleep 2
        return false
      end

      require 'rubygems'
      require @installed_files['coupler-dependencies']
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
      @web_server.run
      Coupler::Base.set(:running, true)

      true
    end

    def launch_browser
      print_update("Launching browser...")

      if !Desktop.desktop_supported?
        # FIXME: don't just return.
        puts "Desktop not supported :("
        return
      end

      desktop = Desktop.desktop
      if !desktop.supported?(Desktop::Action::BROWSE)
        # FIXME: don't just return.
        puts "Desktop browse not supported :("
        return
      end

      uri = java.net.URI.new("http://localhost:4567/")
      desktop.browse(uri.java_object)
    end

    def setup_tray_icon
      return if !SystemTray.supported?   # FIXME: don't just return.

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

      @tray.remove(@tray_icon)
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
