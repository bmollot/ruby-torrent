require_relative 'bitfield'
require_relative 'queue'

# This class represents a connection to a peer in a swarm.
# It provides means to easily connect and exchange data with said peer.
class Peer
  attr_reader :tor, :addr, :port, :id, :choking, :interested, :peer_choking, :peer_interested, :have_map, :dled, :uped, :d_rate, :u_rate, :last_updated_rates, :connect_time, :dead

  BLOCK_SIZE = 1 << 14 # 16KB

  def initialize(tor, addr, port)
    @dead = true
    @dled = 0 # Bytes downloaded from peer
    @dled_last = 0
    @uped = 0 # Bytes uploaded to peer
    @uped_last = 0
    @d_rate = 0 # Bytes/s
    @u_rate = 0
    @last_updated_rates = Time.now
    @connect_time = nil
    @tor = tor
    @addr = addr
    @port = port
    @choking = true
    @interested = false
    @peer_choking = true
    @peer_interested = false
    @have_map = Array.new(tor.mi.pieces.length, false) # Start assuming peer has no pieces
    @req_cb = Hash.new # Keeps track of callbacks for sent requests
    @choke_cb = Array.new # keeps track of callbacks for when we're choked
    @msg_count = 0
  end

  # @return [Boolean] success
  def handshake
    pstr = "BitTorrent protocol"
    msg = [pstr.bytesize, pstr, "\x00" * 8, @tor.mi.info_hash, @tor.peer_id].pack("CA#{pstr.bytesize}A8A20A20")
    @s.send(msg, 0) # 0 indicates no special options
    buf = @s.read(1)
    return [false, "Peer hung up"] if buf.nil?
    pstrlen = buf.unpack1("C")
    opstr = @s.read(pstrlen)
    # Fail if protocol versions are mismatched
    return [false, "Mismatched pstr #{opstr}"] if (pstr <=> opstr) != 0
    @s.read(8) # Skip reserved bytes, we don't support DHT anyway
    info_hash = @s.read(20)
    # Fail if info hashes don't match
    return [false, "Hash mismatch"] if (info_hash <=> @tor.mi.info_hash) != 0
    @id = @s.read(20)
    return true
  end

  def a_handshake
    pstr = "BitTorrent protocol"
    msg = [pstr.bytesize, pstr, "\x00" * 8, @tor.mi.info_hash, @tor.peer_id].pack("CA#{pstr.bytesize}A8A20A20")
    buf = @s.read(1)
    return [false, "Peer hung up"] if buf.nil?
    pstrlen = buf.unpack1("C")
    opstr = @s.read(pstrlen)
    # Fail if protocol versions are mismatched
    return [false, "Mismatched pstr #{opstr}"] if (pstr <=> opstr) != 0
    @s.read(8) # Skip reserved bytes, we don't support DHT anyway
    info_hash = @s.read(20)
    # Fail if info hashes don't match
    return [false, "Hash mismatch"] if (info_hash <=> @tor.mi.info_hash) != 0
    # Send our part after confirming matching hashes
    @s.send(msg, 0) # 0 indicates no special options
    # We can only be sure that they'll send their id after seing our hash
    @id = @s.read(20)
    return true
  end

  def connect
    $log.info "Attempting connection to peer at #{@addr}:#{@port}"
    # Establish TCP connection
    begin
      @s = TCPSocket.new(@addr, @port)
    
      # Shake hands
      success, err = self.handshake
    rescue
      return [false, "Connection refused"]
    end
    return [false, "Failed handshake: " + err] if not success
    self.s_bitfield
    # Set up keep-alive polling
    @ka_thr = Thread.new {loop do sleep 60; self.s_keep_alive() end}
    # Establish listen thread
    @in_thr = Thread.new do
      self.listen
      # If this is reached, connection is dead
      self.disconnect()
    end
    @connect_time = Time.now
    @dead = false
    return [true, nil]
  end

  def incomming(socket)
    $log.info "Incomming connection from #{@addr}:#{@port}"
    @s = socket
    # Shake hands
    success, err = self.a_handshake
    return [false, "Failed handshake: " + err] if not success
    self.s_bitfield
    # Set up keep-alive polling
    @ka_thr = Thread.new {loop do sleep 60; self.s_keep_alive() end}
    # Establish listen thread
    @in_thr = Thread.new do
      self.listen
      # If this is reached, connection is dead
      self.disconnect()
    end
    @connect_time = Time.now
    @dead = false
    return [true, nil]
  end

  def disconnect
    @ka_thr.exit
    if not @s.closed? and not @dead
      self.s_choke() if not @choking
      self.s_not_interested() if not @interested
      @s.close()
    end
    @dead = true
    $log.info "Disconnected from #{self}"
  end

  def update_rates
    if @dead
      @d_rate = 0
      @u_rate = 0
      return
    end
    d = @dled - @dled_last
    @dled_last = @dled
    u = @uped - @uped_last
    @uped_last = @uped
    interval = Time.new - @last_updated_rates
    @d_rate = d / interval
    @u_rate = u / interval
    @last_updated_rates = Time.now
  end

  # Don't call this in the main thread; it blocks and never terminates.
  def listen
    begin
      while not @s.closed?
        # Wait for up to two minutes for data to be sent,
        # terminating "listen" with an error if input times out.
        timeout = 120
        r = IO.select([@s], [], [], timeout)
        return false, "Went #{timeout} seconds without input" if r.nil?

        # Now process the message
        buf = @s.read(4)
        break if buf.nil? # If read fails, socket have been closed, so stop listening
        msglen = buf.unpack1("L>")
        next if msglen == 0 # Special case for keep alive messages (do nothing)
        type, payload = @s.read(msglen).unpack("Ca#{msglen - 1}")
        case type
        when 0
          self.h_choke()
        when 1
          self.h_unchoke()
        when 2
          self.h_interested()
        when 3
          self.h_not_interested()
        when 4
          index = payload.unpack1("L>")
          self.h_have(index)
        when 5
          self.h_bitfield(payload)
        when 6
          index, offset, length = payload.unpack("L>L>L>")
          self.h_request(index, offset, length)
        when 7
          index, offset, block = payload.unpack("L>L>a#{payload.bytesize - 8}")
          self.h_piece(index, offset, block)
          @uped += block.bytesize
        when 8
          index, offset, length = payload.unpack("L>L>L>")
          self.h_cancel(index, offset, length)
        end # Unknown message types are simply ignored (i.e. 9:Port is ignored because we don't support DHT)
        @msg_count += 1
      end
    rescue
      @dead = true
      @s.close
      self.disconnect()
    end
  end

  def set_have(index)
    @have_map[index] = true
    if (not @tor.pdb.piecemap[index].have) and (not @interested)
      self.s_interested
    end
  end

  def calc_interest
    wants = @tor.pdb.piecemap.map {|x| x.have}.zip(@have_map).map {|x,y| (not x) and y}
    if wants.any? and (not @interested)
      self.s_interested
    end
  end

  def register_choke_callback(&cb)
    @choke_cb.push(cb)
    return cb
  end
  def deregister_choke_callback(key)
    @choke_cb.delete(key)
  end

  def h_choke
    $log.debug "#{self} <- choke"
    @peer_choking = true
    @choke_cb.each {|cb| cb.call}
  end
  def h_unchoke
    $log.debug "#{self} <- unchoke"
    @peer_choking = false
  end
  def h_interested
    $log.debug "#{self} <- interested"
    @peer_interested = true
  end
  def h_not_interested
    $log.debug "#{self} <- not interested"
    @peer_interested = false
  end
  def h_have(index)
    $log.debug "#{self} <- have #{index}"
    self.set_have(index)
  end
  def h_bitfield(field)
    $log.debug "#{self} <- bitfield #{field.bytes.map{|b| b.to_s(16)}.join}"
    if @msg_count != 0
      $log.debug "#{self} <- bitfield, but it wasn't the first message after handshake"
      self.disconnect()
    end
    haves = BitField::to_array(field)
    len, trailing = BitField::coded_length(@tor.pdb.piecemap.length)
    trail = haves.pop(trailing)
    if (haves.length != @tor.pdb.piecemap.length) or (trail.any? {|b| b != 0})
      $log.debug "Got invalid bitfield"
      self.disconnect()
    end
    # Now actually handle the field
    haves.each_with_index {|b,i| if b == 1 then self.set_have(i) end}
  end
  def h_request(index, offset, length)
    $log.debug "#{self} <- request (#{index}, #{offset}, #{length})"
    return if @choking # Ignore requests from peers we are choking
    # These errors deserve a d/c. Requests too large a block or request a piece we don't have or requests past the end of a piece
    if (length > BLOCK_SIZE) or (not @tor.pdb.piecemap[index].have) or (offset + length > @tor.pdb.piecemap[index].size)
      self.disconnect()
      return
    end
    @tor.up_queue.enqueue([Request.new(self, index, offset, length, nil)])
  end
  def h_piece(index, offset, block)
    $log.debug "#{self} <- piece (#{index}, #{offset}, #{block.bytesize})"
    @req_cb[[index, offset, block.length]].call(true, block)
  end
  def h_cancel(index, offset, length)
    $log.debug "#{self} <- cancel (#{index}, #{offset}, #{length})"
    @tor.up_queue.dequeue([Request.new(self, index, offset, length, nil)])
  end

  def send_msg(id, msg = nil)
    return if @s.closed? # if I messed up somewhere and there's a case where I try to send a message over a dead connection, return rather than panic
    msg = "" if msg.nil?
    msg = [1 + msg.bytesize, id, msg].pack("L>CA#{msg.length}")
    @s.send(msg, 0)
  end
  def s_keep_alive
    @s.send("\x00" * 4, 0)
  end
  def s_choke
    $log.debug "#{self} -> choke"
    @tor.up_queue.cancel(self)
    self.send_msg(0)
    @choking = true
  end
  def s_unchoke
    $log.debug "#{self} -> unchoke"
    self.send_msg(1)
    @choking = false
  end
  def s_interested
    $log.debug "#{self} -> interested"
    self.send_msg(2)
    @interested = true
  end
  def s_not_interested
    $log.debug "#{self} -> not interested"
    self.send_msg(3)
    @interested = false
  end
  def s_have(index)
    $log.debug "#{self} -> have #{index}"
    self.send_msg(4, [index].pack("L>"))
  end
  def s_bitfield
    field = BitField::from_array(@tor.pdb.piecemap.map {|p| p.have ? 1 : 0})
    $log.debug "#{self} -> bitfield #{field.bytes.map{|b| b.to_s(16)}.join}"
    self.send_msg(5, field)
  end
  # The spec calls offset "begin", but that's a Ruby reserved word, hence the replacement
  def s_request(index, offset, length, &cb)
    $log.debug "#{self} -> request (#{index}, #{offset}, #{length})"
    @req_cb[[index, offset, length]] = Proc.new {|*args| cb.call(*args)}
    self.send_msg(6, [index, offset, length].pack("L>L>L>"))
  end
  def s_piece(index, offset, block, &cb)
    $log.debug "#{self} -> piece (#{index}, #{offset}, #{block.bytesize})"
    self.send_msg(7, [index, offset, block].pack("L>L>A"))
    cb.call()
  end
  def s_cancel(index, offset, length)
    $log.debug "#{self} -> cancel (#{index}, #{offset}, #{length})"
    self.send_msg(8, [index, offset, length].pack("L>L>L>"))
  end

  def to_s
    return "Peer<#{@addr}:#{@port}>"
  end

end
