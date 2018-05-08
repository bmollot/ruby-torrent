require 'net/http'
require 'ipaddr'

class Tracker
  attr_reader :seeders, :leechers, :peer_pool, :interval, :min_interval

  # @param mi [MetaInfo]
  def initialize(mi)

    @seeders = nil
    @leechers = nil
    @peer_pool = Array.new

    # @type [MetaInfo]
    @mi = mi
    @uri = URI(mi.announce)
    @key = Random.new.bytes(20)
    @trackerid = nil
    @interval = 120
    @min_interval = 0
    @last_announce = Time.at(0) # Epoch
  end
  def announce(to, ev = nil)
    # Refuse to announce if the minimum interval hasn't elapsed
    if Time.now - @last_announce < @min_interval
      return nil
    end
    params = {
      info_hash: @mi.info_hash,
      peer_id: to.peer_id,
      port: $listen_port,
      uploaded: to.uploaded,
      downloaded: to.downloaded,
      left: to.left,
      compact: 1,
      ip: $listen_ip,
      key: @key
    }
    # Handle event symbols
    case ev
    when :start
      params[:event] = "started"
    when :stop
      params[:event] = "stopped"
    when :done
      params[:event] = "completed"
    when :need_peers
      parame[:numwant] = 100
    end
    # Only use a trackerid if one has been announced
    if not @trackerid.nil?
      params[:trackerid] = @trackerid
    end
    @uri.query = URI.encode_www_form(params)
    res = Net::HTTP.get_response(@uri)
    @last_announce = Time.now
    case res
    when Net::HTTPError
      $log.debug "Failed to connect to tracker, aborting..."
      return nil, res
    when Net::HTTPSuccess
      $log.debug "Successfully connected to tracker!"
    else
      $log.warn "Got unknown response type, aborting...\n#{res}"
      exit 2
    end
    res = TrackerResponse.new(res.body)
    # Update tracked values
    @min_interval = res.min_interval if not res.min_interval.nil?
    @tracker_id = res.tracker_id if not res.tracker_id.nil?
    @interval = res.interval if not res.interval.nil?
    @seeders = res.complete if not res.complete.nil?
    @leechers = res.incomplete if not res.incomplete.nil?
    @peer_pool = res.peers if not res.peers.nil?
    return res
  end
end

# :id can be, and often is, nil
PeerEntry = Struct.new(:id, :ip, :port)

class TrackerResponse
  attr_reader :failure_reason, :success, :warning_message, :min_interval, :tracker_id, :interval, :complete, :incomplete, :peers

  def initialize(o)
    case o
    when String
      res = BEncode.decode(o)
    when Hash
      res = o
    else
      raise ArgumentError.new("Invalid argument type for TrackerResponse initialization")
    end

    $log.debug "Got tracker response: #{res}"

    # First detect failure
    @failure_reason = res["failure reason"]
    @success = (@failure_reason.nil?)
    return if not @success
    # It seems like all of these entries may be ommitted, so make sure to handle nil values
    @warning_message = res["warning message"] # display if present
    @min_interval = res["min interval"] # MUST be abided by if present (seconds)
    @tracker_id = res["tracker id"] # this is actually required initially, but becomes optional for subsequent responses
    @interval = res["interval"] # this is advisory, but we'll follow it (seconds)
    @complete = res["complete"] # seeders
    @incomplete = res["incomplete"] # leechers
    # Except peers? It's just empty if no peers are reported, not absent
    # Detect type of peers response and parse to same storage format regardless
    peers = res["peers"]
    case peers
    when Array
      @peers = peer.map {|x| PeerEntry.new(x["peer id"], IPAddr.new(x["ip"]), x["port"])}
    when String
      @peers = Array.new
      for i in 0...(peers.bytesize / 6)
        ip = IPAddr.new_ntoh(peers.byteslice(i * 6, 4).b)
        port = peers.byteslice(i * 6 + 4, 2).unpack1("S>")
        @peers.push(PeerEntry.new(nil, ip, port))
      end
    else
      raise EncodingError.new("Got invalid peers encoding")
    end
  end
end
