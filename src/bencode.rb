module BEncode
  def self.encode(data)
    return self::BWriter.new.write(data).state
  end
  def self.decode(str)
    return self::BParser.new(str.b).parse_next
  end

  private
  class BWriter
    def initialize
      @state = ""
    end
    def state
      return @state
    end
    def write(o)
      case o
      when Integer
        self.write_int(o)
      when String
        self.write_string(o)
      when Array
        self.write_list(o)
      when Hash
        self.write_dict(o)
      else
        raise ArgumentError.new("Cannot serialize argument " + o)
      end
      return self
    end
    def write_int(i)
      @state.concat('i', i.to_s, 'e')
    end
    def write_string(s)
      @state.concat(s.bytesize.to_s, ':', s)
    end
    def write_list(a)
      @state.concat('l')
      for x in a do
        self.write(x)
      end
      @state.concat('e')
    end
    def write_dict(h)
      ks = h.keys.sort!
      @state.concat('d')
      for k in ks do
        v = h[k]
        self.write_string(k)
        self.write(v)
      end
      @state.concat('e')
    end
  end
  class BParser
    def initialize(init_str)
      @state = init_str
    end
    def parse_next
      case @state[0]
      when 'i' # Integer
        return self.parse_int
      when /^\d/ # Byte String
        return self.parse_string
      when 'l' # List
        return self.parse_list
      when 'd' # Dictionary
        return self.parse_dict
      else
        return nil
      end
    end
    def parse_int
      # Match 'i' at beginning of string, followed by either '0'
      # or an optional '-' followed by one or more digits not led by a '0'
      # i.e. any valid bencoded integer
      m = /^i(0|-?[1-9]+\d*)e/.match(@state)
      # Abort with nil return if match failed
      return nil if m.nil?
      # Convert the match to the integer it represents
      i = m[1].to_i
      # Remove the matched substring from the beginning of our bstring
      @state.delete_prefix!(m.to_s)
      # Return native representation of the parsed value on success
      return i
    end
    def parse_string
      # Match a normalized decimal string followed by ':'
      # i.e. any valid bencoded byte string "header"
      m = /^(0|[1-9]+\d*):/.match(@state)
      # Abort with nil return if match failed
      return nil if m.nil?
      # Convert the match to the integer string length it represents
      i = m[1].to_i
      # Remove the header from the string being parsed
      @state.delete_prefix!(m.to_s)
      # Read the number of bytes specified by the header
      bs = @state[0, i]
      # and delete them from the string being parsed too
      @state.delete_prefix!(bs)
      # Finally return the read bytes
      return bs.force_encoding("UTF-8")
    end
    def parse_list
      # Abort if header is wrong for a list
      return nil if @state[0] != 'l'
      # chomp the header
      @state.delete_prefix!('l')
      # Now detect and chomp elements until the end is found
      l = Array.new
      loop do
        # Exit loop if end token is next
        break if @state.delete_prefix!('e') != nil
        l.push self.parse_next
      end
      # Return the representations of the encoded elements of the list
      return l
    end
    def parse_dict
      # Abort if header is wrong for a dictionary
      return nil if @state[0] != 'd'
      # chomp the header
      @state.delete_prefix!('d')
      # Now detect and chomp key/value pairs until the end is found
      d = Hash.new
      lk = nil
      loop do
        # Exit loop if end token is next
        break if @state.delete_prefix!('e') != nil
        k = self.parse_string
        # abort if keys are out of order
        return nil if lk != nil and k < lk
        d[k] = self.parse_next
        lk = k
      end
      # Return the representations of the encoded elements of the dict
      return d
    end
  end
end
