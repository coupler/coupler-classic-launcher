require 'java'
require 'rbconfig'
require 'rubygems'
require 'rubygems/format'

module Coupler
  class Launcher
    include java.lang.Runnable
    include_package 'java.awt'

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

    def say(string)
      width = @font_metrics.string_width(string)
      @graphic.color = Color::WHITE
      @graphic.fill_rect(TEXT_X, TEXT_Y - 30, TEXT_W, 60)
      @graphic.color = Color::BLACK
      @graphic.draw_string(string, TEXT_X + (TEXT_W - width) / 2, TEXT_Y)
      @splash.update
    end

    def find_coupler_dir
      say("Locating Coupler directory...")

      # NOTE: Unfortunately, this code is in two places. Coupler can
      # be run with or without the launcher, and the launcher needs
      # to know about Coupler's data path before it runs Coupler.
      dir =
        if ENV['COUPLER_HOME']
          ENV['COUPLER_HOME']
        else
          case Config::CONFIG['host_os']
          when /mswin|windows/i
            # Windows
            File.join(ENV['APPDATA'], "coupler")
          else
            if ENV['HOME']
              File.join(ENV['HOME'], ".coupler")
            else
              raise "Can't figure out where Coupler lives! Try setting the COUPLER_HOME environment variable"
            end
          end
        end
      if !File.exist?(dir)
        begin
          Dir.mkdir(dir)
        rescue SystemCallError
          raise "Can't create Coupler directory (#{dir})! Is the parent directory accessible?"
        end
      end
      if !File.writable?(dir)
        raise "Coupler directory (#{dir}) is not writable!"
      end
      @coupler_dir = File.expand_path(dir)
      puts "COUPLER DIR: #{@coupler_dir}"

      @gems_dir = File.join(@coupler_dir, "gems")
      Gem.use_paths(@gems_dir, [@gems_dir])
    end

    def install_or_update_coupler
      # Borrowing ideas from JRuby's maybe_install_gems command

      say("Checking Coupler version...")
      gem_name = "coupler"

      # Want the kernel gem method here; expose a backdoor b/c RubyGems 1.3.1 made it private
      Object.class_eval { def __gem(g); gem(g); end }
      gem_loader = Object.new

      command = "install"
      begin
        gem_loader.__gem(gem_name)
        command = "update"
        say("Checking for updates...")
      rescue Gem::LoadError
        say("Installing Coupler...")
      end

      Object.class_eval { remove_method :__gem }

      old_paths = Gem.paths
      old_argv = ARGV.dup
      ARGV.clear
      ARGV.push(command, "-i", @gems_dir, gem_name)
      begin
        load Config::CONFIG['bindir'] + "/gem"
      rescue SystemExit => e
        # don't exit in case of 0 return value from 'gem'
        exit(e.status) unless e.success?
      end
      ARGV.clear

      # TODO: cleanup

      ARGV.push(*old_argv)
      Gem.paths = {"GEM_HOME" => old_paths.home, "GEM_PATH" => old_paths.path}
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

    def start_coupler
      # FIXME: ensure coupler is installed; it might not be if
      # for some reason it can't be found in the gem repos
      require 'coupler'
      @runner = Coupler::Runner.new([], :trap => false) { |msg| say(msg) if @splash }
      true
    end

    def launch_browser
      say("Launching browser...")

      if !Desktop.desktop_supported?
        puts "Can't open browser. Desktop not supported :("
        puts "Please go to http://localhost:4567 manually"
        return
      end

      @desktop = Desktop.desktop
      if !@desktop.supported?(Desktop::Action::BROWSE)
        @desktop = nil
        puts "Can't open browser. Desktop browse not supported :("
        puts "Please go to http://localhost:4567 manually"
        return
      end

      @local_uri = java.net.URI.new("http://localhost:4567/")
      @desktop.browse(@local_uri.java_object)
    end

    def setup_tray_icon
      if !SystemTray.supported?
        puts "Can't open system tray :("
        trap("INT") do
          shutdown
        end
        @runner.join

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

      if @desktop
        open_item = MenuItem.new("Open")
        open_item.add_action_listener do |e|
          @desktop.browse(@local_uri.java_object)
        end
        popup.add(open_item)
      end

      quit_item = MenuItem.new("Quit")
      quit_item.add_action_listener do |e|
        shutdown
      end
      popup.add(quit_item)

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
      @runner.shutdown

      if @tray
        @tray.remove(@tray_icon)
      end
    end

    def run
      setup_gui
      find_coupler_dir
      install_or_update_coupler
      if start_coupler
        launch_browser
        @splash.close
        @splash = nil

        setup_tray_icon
      end
    end
  end
end
