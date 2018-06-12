# Some ruby 2.5.0 polyfill
# Curse this ancient VM
class String
  def delete_prefix!(pre)
    if not self.start_with?(pre)
      return nil
    end
    self.slice!(0, pre.bytesize)
    return self
  end
  alias_method :concat1, :concat
  def concat(*objs)
    objs.each do |obj|
      self.concat1(obj)
    end
    return self
  end
  def unpack1(fmt)
    return self.unpack(fmt)[0]
  end
end
class Array
  def concat(*arrs)
    arrs.each do |arr|
      self.push(*arr)
    end
    return self
  end
  def sum
    return self.reduce(:+)
  end
end

require_relative 'torrent'
require 'pathname'
require 'ipaddr'
require 'open3'
require 'logger'

# Global values? In my program? Unforgivable. #

# By default torrents are downloaded to CWD
$storage_dir = Pathname.getwd
$log = Logger.new(STDOUT)
$log.level = :debug
# This is super bittle, but I couldn't find a cleaner way of getting my ip short of using sockets to perfrom a manual dig
ext_ip_str = Open3.capture3('dig', '+short', 'myip.opendns.com', '@resolver1.opendns.com')
$listen_ip = IPAddr.new(ext_ip_str[0].chomp)
$listen_port = 6881

if ARGV.length < 1
  puts "usage: client <metainfo.torrent>"
  exit 1
end
to = Torrent.new(ARGV[0])
to.start
