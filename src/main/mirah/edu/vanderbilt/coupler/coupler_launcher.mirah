import java.lang.ClassLoader
import java.lang.Thread
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.FilenameFilter
import java.net.URL
import java.net.HttpURLConnection
import java.net.URLClassLoader
import java.util.ArrayList
import java.util.Date
import java.util.regex.Pattern
import java.text.SimpleDateFormat
import java.security.MessageDigest
import org.jsoup.Jsoup

class CouplerContainer < Thread
  def initialize(class_loader:URLClassLoader, local_coupler_jar:File)
    @class_loader = class_loader
    @local_coupler_jar = local_coupler_jar
  end

  def run:void
    klass = @class_loader.loadClass("org.jruby.embed.ScriptingContainer")
    container = klass.newInstance

    parameter_types = Class[1]; parameter_types[0] = String.class
    method = klass.getDeclaredMethod("runScriptlet", parameter_types)
    load_path = "file:" + @local_coupler_jar.toURI.getSchemeSpecificPart + "!/META-INF/coupler.home/lib"
    args = Object[1]
    args[0] = <<-EOF
      # tell jRuby's classloader about the jar
      require '#{@local_coupler_jar.getAbsolutePath}'

      # put coupler.home/lib in the load path
      $LOAD_PATH.unshift("#{load_path}")

      require 'coupler'
      begin
        Coupler::Runner.new([])
      rescue SystemExit
      end
    EOF
    method.invoke(container, args)
  end
end

class CouplerLauncher
  def initialize
    @latest_available_jar_url = URL(nil)
    find_coupler_dir
    find_latest_available_jar
    install_latest_available_jar
    run_coupler
  end

  def find_coupler_dir:void
    user_home = System.getProperty("user.home")
    @coupler_dir = File.new(File.new(user_home), user_home.startsWith("/") ? ".coupler" : "coupler")
    if !@coupler_dir.exists
      @coupler_dir.mkdir
    end
  end

  def find_latest_available_jar:void
    github_url = "https://github.com/coupler/coupler/downloads"
    doc = Jsoup.connect(github_url).get
    elts = doc.select('ol#manual_downloads')
    if elts.size == 0
      raise "Can't connect to github"
    end
    ol = elts.get(0)

    date_formatter = SimpleDateFormat.new("EEE MMM d HH:mm:ss zzz yyyy")
    latest_date = Date.new(long(0))
    latest_href = String(nil)
    lis = ol.select('li')
    i = 0
    while i < lis.size
      li = lis.get(i)

      links = li.select('h4 a')
      if links.size == 0
        next
      end

      abbrs = li.select('abbr')
      if abbrs.size == 0
        next
      end
      abbr = abbrs.get(0)
      date = date_formatter.parse(abbr.html)
      if latest_date.compareTo(date) < 0
        latest_date = date
        latest_href = links.get(0).attr('href')
      end
      i += 1
    end
    if latest_href != nil
      @latest_available_jar_url = URL.new(URL.new(github_url), latest_href)
    end
  end

  def get_md5(file:File)
    # http://www.rgagnon.com/javadetails/java-0416.html
    fis = FileInputStream.new(file)
    buffer = byte[1024]
    complete = MessageDigest.getInstance("MD5")
    num_read = 0
    while num_read != -1
      num_read = fis.read(buffer)
      if num_read > 0
        complete.update(buffer, 0, num_read)
      end
    end
    fis.close
    String.new(Hex.encodeHex(complete.digest))
  end

  def install_latest_available_jar:void
    if @latest_available_jar_url == nil
      # FIXME: local_coupler_jar won't be set
      return
    end
    # get the basename
    pattern = Pattern.compile(".*?([^/]*)$")
    matcher = pattern.matcher(@latest_available_jar_url.toString)
    if !matcher.matches
      raise "Bad Coupler URL :("
    end
    basename = matcher.group(1)
    @local_coupler_jar = File.new(@coupler_dir, basename)

    # Github's download urls are probably redirections, which
    # sucks because they redirect from https to http, which
    # HttpURLConnection won't follow because of security issues
    conn = HttpURLConnection(@latest_available_jar_url.openConnection)
    response_code = conn.getResponseCode
    while response_code == 302
      @latest_available_jar_url = URL.new(@latest_available_jar_url, conn.getHeaderField('Location'))
      conn = HttpURLConnection(@latest_available_jar_url.openConnection)
      response_code = conn.getResponseCode
    end
    if response_code != 200
      puts "Something went wrong when checking for new Coupler versions: #{conn.getResponseMessage}"
      puts "Aborting... :("
      return
    end

    if @local_coupler_jar.exists
      # check the md5
      calculated_md5 = get_md5(@local_coupler_jar)
      expected_md5 = conn.getHeaderField("ETag").replaceAll("\"", "")
      if expected_md5 == null
        puts "Didn't find an ETag. I guess I'll assume the existing file is okay..."
      else
        if calculated_md5.compareTo(expected_md5) != 0
          puts "The local file seems to be corrupt, so ignoring it."
        else
          return
        end
      end
    end

    # grab the new jar file
    puts "There's a new Coupler version available. Fetching..."

    reader = conn.getInputStream
    writer = FileOutputStream.new(@local_coupler_jar)
    buffer = byte[131072]
    total_bytes_read = 0
    bytes_read = reader.read(buffer)
    out = System.out
    while bytes_read > 0
      total_bytes_read += bytes_read
      out.print("\r#{total_bytes_read / 1024}KB")
      out.flush
      writer.write(buffer, 0, bytes_read)
      bytes_read = reader.read(buffer)
    end
    writer.close
    reader.close
    puts "\nDone fetching."

    # unlink old jars
    @coupler_dir.listFiles.each do |f|
      if f.getPath.endsWith(".jar") && f.compareTo(@local_coupler_jar) != 0
        f.delete
      end
    end
  end

  def run_coupler:void
    urls = URL[1]; urls[0] = @local_coupler_jar.toURL
    puts urls[0].toString
    cl = URLClassLoader.new(urls)
    thr = CouplerContainer.new(cl, @local_coupler_jar)
    thr.setContextClassLoader(cl)
    thr.start
    thr.join
  end
end

CouplerLauncher.new
