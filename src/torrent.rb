require_relative 'metainfo'
require_relative 'tracker'
require_relative 'peer'
require_relative 'queue'
require_relative 'downloader'
require_relative 'piecedb'
require 'socket'

class Torrent
  attr_accessor :target_peers
  attr_reader :peer_id, :uploaded, :downloaded, :total_size, :mi, :pdb, :peers, :seeding, :up_queue

  def initialize(o, target_peers: 30)
    @seeding = false
    @recent_cutoff = 120 # Age of a connection in seconds that is still considered new
    @target_peers = target_peers
    @mi = MetaInfo.new(o)
    @tr = Tracker.new(@mi)
    @peer_id = "-dt-0001" + Random.new.bytes(12)
    @peers = Array.new
    @dlers = Array.new
    @uploaded = 0 # bytes
    @downloaded = 0 # also bytes
    @up_queue = UpQueue.new
    if @mi.single_file
      @target_dir = $storage_dir
    else
      @target_dir = $storage_dir + @mi.dir_name
    end
    # The PieceDB subdir name is the first 5 bytes of the torrent's infohash in hex
    dbdir = @mi.info_hash.bytes.first(5).map {|b| b.to_s(16)}.join
    @pdb = PieceDB.new($storage_dir + dbdir, @mi)
    @total_size = @mi.files.reduce(0) {|sum, x| sum + x.length}
  end

  def left
    return @total_size - @pdb.size
  end

  def drop_dead_peers!
    @peers.reject! {|pe| pe.dead}
  end

  # @return [Boolean] true if tried to get more peers, false if already had enough
  def find_peers
    $log.info "Looking for new peers..."
    # First filter out dead peers
    self.drop_dead_peers!()
    # Then get new peers if necessary
    want = @target_peers - @peers.length
    $log.info "I want #{want} more peers"
    return false if want <= 0
    # Try to connect to selected peers, each in its own thread
    conn_trs = @tr.peer_pool.sample(want).map do |pe|
      Thread.new do
        pe = Peer.new(self, pe.ip.to_string, pe.port)
        success, err = pe.connect
        if success
          $log.info "Connected to peer #{pe.addr}:#{pe.port}"
          @peers.push(pe)
        else
          $log.info "Failed to connect to peer #{pe.addr}:#{pe.port}"
          $log.info err
        end
      end
    end
    # Then join with a timeout of 10 seconds in total
    Thread.new {conn_trs.each {|thr| thr.join}}.join(10)

    return true
  end

  def start
    # Announce start
    @tr.announce(self, :start)
    self.find_peers()
    # Set up tracker polling
    # and sure, update peers here too, why not?
    @poll_thr = Thread.new do
      loop do
        sleep @tr.interval
        $log.debug "Polling tracker..."
        @tr.announce(self)
        self.find_peers()
      end
    end
    # Evaluate choke status of peers every 10 seconds
    @choke_thr = Thread.new do
      optimist = nil
      choke_count = 0
      loop do
        sleep 10
        self.drop_dead_peers!() # Make sure we're not dealing with dead peers
        next if @peers.length <= 0
        # 30 seconds have passed, change optimitic unchoke
        if choke_count == 0
          pot = Array.new
          now = Time.now
          @peers.each do |pe|
            # New peers are three times more common in the pot
            if now - pe.connect_time <= @recent_cutoff
              pot.push(pe, pe, pe)
            else
              pot.push(pe)
            end
          end
          # Pick an optimist from the pot of all peers
          optimist = pot[Random.new.rand(pot.length)]
        end
        # Increment choke_count mod 3
        choke_count += 1
        choke_count = choke_count % 3
        # Always do this stuff
        interested_peers = Array.new
        uninterested_peers = Array.new
        @peers.each do |pe|
          pe.update_rates()
          if pe.peer_interested
            interested_peers.push(pe)
          else
            uninterested_peers.push(pe)
          end
        end
        # Use uninterested peers as our downloaders if there are no interested peers
        if interested_peers.length == 0
          interested_peers.concat(uninterested_peers.sample(4))
        end
        if @seeding
          # 4 interested peers we are uploading to fastest
          dlers = interested_peers.sort {|x,y| y.u_rate <=> x.u_rate}.take(4)
          cutoff_rate = dlers[0].u_rate
          dlers.pop() if optimist.peer_interested and (not dlers.include?(optimist)) and dlers.length == 4 # optimist can take up a dlers slot
          to_unchoke = [optimist].concat(dlers, uninterested_peers.select {|pe| pe.u_rate >= cutoff_rate})
        else
          # 4 interested peers we are downloading from fastest
          dlers = interested_peers.sort {|x,y| y.d_rate <=> x.d_rate}.take(4)
          cutoff_rate = dlers[0].d_rate
          dlers.pop() if optimist.peer_interested and (not dlers.include?(optimist)) and dlers.length == 4 # optimist can take up a dlers slot
          to_unchoke = [optimist].concat(dlers, uninterested_peers.select {|pe| pe.d_rate >= cutoff_rate})
        end
        # Inform peers of changes to who we're choking
        total_dl_s = 0
        total_up_s = 0
        @peers.each do |pe|
          total_dl_s += pe.d_rate
          total_up_s += pe.u_rate
          if to_unchoke.include?(pe)
            pe.s_unchoke if pe.choking
          else
            pe.s_choke if not pe.choking
          end
        end

        # This is **not** a mistake, it's just confusingly named
        $log.info "DL: #{total_up_s.to_i}B/s | UP: #{total_dl_s.to_i}B/s"
        if not total_up_s == 0
          min, sec = (self.left / total_up_s).to_i.divmod(60)
          $log.info "Estimated time remaining: #{min} minutes, #{sec} seconds"
        end
      end
    end

    # Listen for incoming connections
    @listen_thr = Thread.new do
      s = TCPServer.open('127.0.0.1', $port)
      loop do
        c = s.accept
        # Refuse connections if we have enough peers
        if @peer.length >= @target_peers
          c.close
          next
        end
        addr = c.remote_address
        peer = Peer.new(self, addr.ip_address, addr.ip_port)
        success, err = peer.incomming(c)
        if success
          $log.info "Connected to by #{peer}"
          @peers.push(pe)
        else
          $log.info "Connection from #{peer} failed"
          $log.info err
        end
      end
    end
    
    # Connect with peers and exchange data
    @dl_thr = Thread.new do
      @downloading = Array.new
      dl_cap = 100
      downloader = Downloader.new(self)
      while not @pdb.done?
        want = dl_cap - @downloading.length
        if want <= 0
          sleep 1
          next
        end
        indicies = self.next_piece(num: want, black_list: @downloading)
        if indicies.empty?
          $log.debug "No wanted and available pieces"
          sleep 1
          next
        end

        indicies.each do |index|
          $log.info "Starting download of piece #{index}"
          @downloading.push(index)
          Thread.new do
            downloader.download(index)
            @downloading.delete(index)
          end
        end
      end
    end
    @dl_thr.join()
    @pdb.construct(@target_dir)

    @seeding = true

    # This should never terminate, it's the seeding loop (sort of)
    @listen_thr.join()
  end
  def stop
    # Stop polling
    @poll_thr.exit if @poll_thr.alive?
    @choke_thr.exit if @choke_thr.alive?
    @dl_thr.exit if @dl_thr.alive?
    @listen_thr.exit if @listen_thr.alive?
    # Announce stop
    @tr.announce(self, :stop)
    # Tear down peer connections gracefully
    @peers.each {|pe| p.disconnect()}
    @peers.clear
  end

  # Choose 'num' pieces to attempt to download next, according to rarest-first
  # with some randomization.
  # @return [Array[Integer]] Piece indicies
  def next_piece(num: 1, n: 10, black_list: [])
    # Look, functional programming!
    # Creates an array of [frequency, index] pairs.
    freq_map = Array.new(@mi.pieces.length, 0).zip(*@peers.map {|pe| pe.have_map.map {|h| h ? 1 : 0}}).map {|x| x.sum}.each_with_index
    # Treat pieces that we already have and blacklisted pieces as unreachable
    freq_map = freq_map.map {|x,i| if @pdb.piecemap[i].have or black_list.include?(i) then [0,i] else [x,i] end}
    # Randomly take 'num' of the 'n' rarest pieces.
    freq_map = freq_map.sort.drop_while {|x,i| x == 0}.take(n).sample(num).map {|x,i| i}
    return freq_map
  end
end
