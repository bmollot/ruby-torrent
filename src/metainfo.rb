require 'digest/sha1'
require 'pathname'
require_relative 'bencode'

FileEntry = Struct.new(:length, :path)

class MetaInfo
  attr_reader :announce, :announce_list, :piece_length, :pieces, :single_file, :files, :dir_name, :creation_date, :comment, :created_by, :encoding, :info_hash
   
  def initialize(src)
    case src
    when File
      self.load_file(src)
    when String
      File.open(src) {|f| self.load_file(f)}
    else
      raise ArgumentError.new("Invalid MetaInfo initialization source")
    end
  end
  def load_file(f)
    mi = BEncode.decode(File.binread(f))
    info = mi["info"]
    # Calculate and store info's hash
    @info_hash = Digest::SHA1.digest(BEncode.encode(info))
    # Read for optional entries first
    @announce_list = mi["announce-list"] # yes, this key really uses a different spacing convention
    @creation_date = mi["creation date"] # see, most just use a real space, but that one uses a hypen
    @comment = mi["comment"] # thats how you can tell it's an unoffical extention
    @created_by = mi["created by"]
    @encoding = mi["encoding"]
    # I'm opting to ignore the optional md5sum field. It seems totally useless and redundant
    if info["private"] == 1
      @private = true
    else
      @private = false
    end

    # Then the core entries
    @announce = mi["announce"]
    name = info["name"]
    @piece_length = info["piece length"]
    # Store pieces as an array of sha1 hashes
    @pieces = Array.new
    pieces = info["pieces"]
    i = 0
    while i < pieces.bytesize
      @pieces.push(pieces.byteslice(i, 20))
      i += 20
    end
    # deal with single and multi-file cases
    l = info["length"] # single file
    if not l.nil?
      @single_file = true
      @files = Array.new
      @files.push(FileEntry.new(l, Pathname.new(name)))
    end
    fs = info["files"]
    if not fs.nil?
      raise EncodingError.new "Found both 'length' and 'files' keys in metainfo" if @single_file
      @single_file = false
      @dir_name = name
      @files = Array.new
      for f in fs
        @files.push(FileEntry.new(f["length"], Pathname.new(f["path"])))
      end
    end
  end
end