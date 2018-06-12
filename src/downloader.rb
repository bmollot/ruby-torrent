require_relative 'queue'


class Downloader
  BLOCK_SIZE = 1 << 14 # 16KB

  def initialize(tor)
    @tor = tor
  end
  
  # Call this in another thread, it will block waiting for download to be done.
  # It will store the downloaded piece in the PieceDB, so set up a callback
  # there if you need to know when it's done.
  # @param index [Integer] The piece index to begin trying to download
  def download(index)
    que = DownQueue.new
    pe = @tor.pdb.piecemap[index]
    return true if pe.have # If we already have the piece, we're done
    # Split the piece into blocks (an array of byte ranges)
    blocks = Array.new
    cur = 0
    while cur < pe.size
      blocks.push(cur...([cur + BLOCK_SIZE, pe.size].min))
      cur += BLOCK_SIZE
    end
    havemap = Array.new(blocks.size, false) # for recording completed blocks
    datamap = Array.new(blocks.size) # for storing data of completed blocks
    while not havemap.all?
      $log.debug "--- Entering piece [#{index}] download loop ---"
      $log.debug "    #{havemap.map{|h| h ? "#" : "-"}.join}"
      # Choose a peer
      @tor.drop_dead_peers!()
      peers = @tor.peers.select {|pe| (not pe.peer_choking) and pe.have_map[index]}

      # Register a callback so we know if the peer chokes us
      keys = peers.map {|peer| peer.register_choke_callback {que.cancel(peer)}}

      reqs = Array.new
      res_count = 0
      blocks.each_with_index.map do |b,i|
        next if havemap[i] # no request if already have block
        p1, p2 = peers.sample(2)
        r1 = Request.new(p1, index, b.first, b.size, nil)
        # r2 = Request.new(p2, index, b.first, b.size, nil)
        cb = Proc.new do |success, data|
          res_count += 1
          if success
            que.dequeue([r1]) #, r2])
            havemap[i] = true
            datamap[i] = data
          end
          $log.debug "[#{index}:#{i}] Callback #{success}, #{res_count}"
        end
        r1.cb = cb
        # r2.cb = cb
        reqs.push(r1) #, r2)
      end
      que.enqueue(reqs)
      # Spin until all the responses are in
      while res_count < reqs.length
        sleep 0.1
      end
      # Deregister callback
      peers.each_with_index {|peer, i| peer.deregister_choke_callback(keys[i])}
      # If we don't have the whole piece, we'll loop, grabbing only missing blocks
    end

    # Reassemble the piece and write it to the PieceDB
    $log.info "Got blocks for piece #{index}"
    pdata = datamap.join
    @tor.pdb.write_piece(index, pdata)
    return true
  end
end