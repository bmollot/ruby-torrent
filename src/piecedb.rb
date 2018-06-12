require 'pathname'
require 'digest/sha1'

# This class acts as an interface to an on-disk "database" of finished pieces of a torrent.
# I say "database" because it's just a directory. The names of the files within indicate
# the index of the piece they contain.
# File names are `<index>.piece` where <index> is left-padded to 10 characters.
# 10 characters is the max width of a string representation of a 32 bit unsigned integer, which is
# how indicies are transmitted. As such, 10 character padding ensures constant file name width, and
# therefor proper lexographical sorting.
PieceEntry = Struct.new(:have, :size) do
  def set(h, s)
    have = h
    size = s
  end
end
class PieceDB
  attr_reader :dir, :size, :piecemap

  # Accept a String or Pathname. Resolve any to a Pathname.
  # Also take the torrent MetaInfo for piece info.
  # Create the directory if it doesn't exist.
  def initialize(dir, mi)
    @mi = mi
    length = mi.pieces.length
    dir = Pathname.new(dir) if dir.is_a?(String)
    dir.mkpath if not dir.exist?
    # @type [Pathname]
    @dir = dir
    @size = 0
    @piecemap = Array.new(length) do |i|
      if i != (length - 1) then
        PieceEntry.new(false, mi.piece_length)
      else
        PieceEntry.new(false, mi.files.map {|f| f.length}.sum % mi.piece_length)
      end
    end
    # Register existing any pieces}
    dir.children.each do |f|
      # Add piece's size to db total
      @size += f.size
      # Register that we have this piece
      i = f.basename.to_s.to_i # should ignore the extention, to_i is pretty lenient
      hash = Digest::SHA1.digest(f.read)
      # Check that the hash is as expected, and mark piece as have if it is
      if hash.eql? mi.pieces[i]
        $log.warn {"File in store #{f.to_s} has wrong hash #{hash.bytes.map{|b| b.to_s(16)}.join}, expected #{mi.pieces[i].bytes.map{|b| b.to_s(16)}.join}"}
      else
        $log.debug {"Found piece #{i} in store, hash #{hash.bytes.map{|b| b.to_s(16)}.join}"}
        @piecemap[i].have = true
      end
    end
  end

  def done?
    return @piecemap.all? {|pe| pe.have}
  end

  def i_to_name(i)
    return (@dir + i.to_s.rjust(10, '0').concat(".piece"))
  end

  # @param index [Integer]
  # @param data [String]
  def write_piece(index, data)
    # If the size is not what we expect for this index, abort and throw
    if data.bytesize != @piecemap[index].size
      raise ArgumentError.new("Data is of wrong size (#{data.bytesize}, expected #{@piecemap[index].size})")
    end
    hash = Digest::SHA1.digest(data)
    if hash.eql? @mi.pieces[index]
      raise ArgumentError.new("Piece data for index #{i} has wrong hash #{hash.bytes.map{|b| b.to_s(16)}.join}, expected #{@mi.pieces[i].bytes.map{|b| b.to_s(16)}.join}")
    end
    f = self.i_to_name(index)
    # Deal with overwriting a piece we already have
    if @piecemap[index].have
      @size -= f.size
    end
    File.binwrite(f.to_path, data)
    @size += data.bytesize # should be the same as f.size now
    # which I use here, so if they're not equal things will break horribly
    @piecemap[index].have = true
    # It's basically as good as unit testing
  end

  # Leaving offset nil should default to 0
  # Leaving length nil should default to the rest of the file
  def read_piece(index, offset, length)
    # Cap length so it's not larger than the rest of the file
    length = [length, @piecemap[index].size - offset].min if not length.nil?
    f = self.i_to_name(index)
    return f.binread(length, offset)
  end

  # Given an output directory and a list of files to build, reconstruct those
  # files from stored pieces
  # @param files [FileEntry] has .length [Integer] and .path [Pathname]
  def construct(dir)
    files = @mi.files
    # Bail if we're missing pieces
    return false if not @piecemap.all? {|p| p.have}
    dir = Pathname.new(dir) if dir.is_a?(String)
    dir.mkpath if not dir.exist?

    index = 0 # current piece
    offset = 0 # offset in current piece
    files.each do |f|
      $log.debug "Writing file #{f}"
      f.path.parent.mkpath() # ensure that the containing directory exists
      f.path.open(mode = "wb") do |fi|
        to_write = f.length
        left = to_write
        # Read pieces, write file
        while left > 0
          buf = self.read_piece(index, offset, left)
          $log.debug "Read #{index}:#{offset} with #{left} left"
          read = buf.bytesize
          fi.write(buf)
          if read < left # hit end of piece, but not done writing file
            # so move on to the beginning of the next piece
            index += 1
            offset = 0
          end
          left -= read
        end
      end
    end
  end
end
