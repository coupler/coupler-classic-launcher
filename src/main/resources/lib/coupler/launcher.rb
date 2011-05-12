require 'java'
require 'rbconfig'
require 'rubygems'
require 'rubygems/dependency_installer'

class Gem::ConfigFile
  # NOTE: Monkey patch ConfigFile so it doesn't load user's gemrc :(
  def initialize(arg_list)
    @config_file_name = nil
    need_config_file_name = false

    arg_list = arg_list.map do |arg|
      if need_config_file_name then
        @config_file_name = arg
        need_config_file_name = false
        nil
      elsif arg =~ /^--config-file=(.*)/ then
        @config_file_name = $1
        nil
      elsif arg =~ /^--config-file$/ then
        need_config_file_name = true
        nil
      else
        arg
      end
    end.compact

    @backtrace = DEFAULT_BACKTRACE
    @benchmark = DEFAULT_BENCHMARK
    @bulk_threshold = DEFAULT_BULK_THRESHOLD
    @verbose = DEFAULT_VERBOSITY
    @update_sources = DEFAULT_UPDATE_SOURCES

    operating_system_config = Marshal.load Marshal.dump(OPERATING_SYSTEM_DEFAULTS)
    platform_config = Marshal.load Marshal.dump(PLATFORM_DEFAULTS)
    system_config = load_file SYSTEM_WIDE_CONFIG_FILE
    #user_config = load_file config_file_name.dup.untaint
    if ENV['COUPLER_DEV']
      user_config = { :sources => %w{http://data.vanderbilt.edu/coupler/} }
    else
      user_config = {}
    end

    @hash = operating_system_config.merge platform_config
    @hash = @hash.merge system_config
    @hash = @hash.merge user_config

    # HACK these override command-line args, which is bad
    @backtrace        = @hash[:backtrace]        if @hash.key? :backtrace
    @benchmark        = @hash[:benchmark]        if @hash.key? :benchmark
    @bulk_threshold   = @hash[:bulk_threshold]   if @hash.key? :bulk_threshold
    @home             = @hash[:gemhome]          if @hash.key? :gemhome
    @path             = @hash[:gempath]          if @hash.key? :gempath
    @update_sources   = @hash[:update_sources]   if @hash.key? :update_sources
    @verbose          = @hash[:verbose]          if @hash.key? :verbose

    load_rubygems_api_key

    Gem.sources = @hash[:sources] if @hash.key? :sources
    handle_arguments arg_list
  end
end
Gem.configuration # force

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

      gems_dir = File.join(@coupler_dir, "gems")
      Gem.use_paths(gems_dir, [gems_dir])
    end

    def install_or_update_coupler
      # Most of this is from what I could figure out by trying to parse
      # the install and update rubygems commands; a lot of copied code

      needed_gems = %w{coupler}
      version = Gem::Requirement.default
      installer_options = {
        :env_shebang => false, :domain => :remote, :force => false,
        :format_executable => false, :ignore_dependencies => false,
        :prerelease => false, :security_policy => nil,
        :wrappers => false, :generate_rdoc => false,
        :generate_ri => false, :version => version,
        :args => needed_gems
      }

      hig = {}  # highest installed gems
      Gem.source_index.each do |name, spec|
        if hig[spec.name].nil? or hig[spec.name].version < spec.version then
          hig[spec.name] = spec
        end
      end

      needed_gems.each do |gem_name|
        if hig[gem_name].nil?
          print_update("Installing #{gem_name}...")

          installer = Gem::DependencyInstaller.new(installer_options)
          installer.install(gem_name, version)
        else
          print_update("Checking #{gem_name}...")

          l_name = gem_name
          l_spec = hig[gem_name]
          dependency = Gem::Dependency.new(l_spec.name, "> #{l_spec.version}")
          fetcher = Gem::SpecFetcher.fetcher
          spec_tuples = fetcher.find_matching dependency

          matching_gems = spec_tuples.select do |(name, _, platform),|
            name == l_name and Gem::Platform.match platform
          end

          if !matching_gems.empty?
            highest_remote_gem = matching_gems.sort_by do |(_, version),|
              version
            end.last
            highest_remote_ver = highest_remote_gem.first[1]

            if l_spec.version < highest_remote_ver
              print_update("Updating #{gem_name}...")
              installer = Gem::DependencyInstaller.new(installer_options)
              installer.install(l_name, version)
            end
          end
        end
      end
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
      @runner = Coupler::Runner.new([], :trap => false) { |msg| print_update(msg) if @splash }
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
