module BitField

  # Wants an Integer Array, containing only 0 and 1 values.
  # Non-0-or-1 values *will* break things.
  def self.from_array(arr)
    field = "".b # binary string
    arr.each_slice(8) do |oct|
      field << octet_to_byte(oct)
    end
    return field
  end

  def self.to_array(field)
    arr = Array.new
    field.each_byte {|b| arr.concat(byte_to_octet(b))}
    return arr
  end

  # Takes the number of bools, returns the number of bytes in a field storing that many bits
  def self.coded_length(len)
    full, diff = len.divmod(8)
    bytes = diff > 0 ? full + 1 : full # Number of bytes in bitfield encoding
    trailing = diff > 0 ? 8 - diff : 0 # Number of trailing 0 bits
    return bytes, trailing
  end

  private

  # @param oct [Array<Integer>] with length 8 (or less; missing bits are assumed to be 0)
  def self.octet_to_byte(oct)
    while oct.length < 8
      oct.push(0)
    end
    byte = 0
    (0...8).each do |i|
      byte = byte | (oct[i] << (7 - i)) # the core bit twiddling
    end
    return byte
  end

  def self.byte_to_octet(byte)
    return 7.downto(0).map {|i| byte[i]}
  end
end
