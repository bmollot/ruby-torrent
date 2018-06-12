Request = Struct.new(:peer, :index, :offset, :length, :cb)

class DownQueue
  attr_reader :size

  # @param size [Integer] Indicates the maximum number of outstanding requests.
  def initialize(size = 100)
    @max_size = size
    @q = Array.new
    @active = Array.new
  end

  def set_size(size)
    @max_size = size
  end

  # Called when a peer wants a request fulfilled
  def enqueue(reqs)
    @q.concat(reqs)
    update()
  end

  # Called when a request is given up on or completed
  def dequeue(reqs)
    reqs.each do |r|
      x = @active.delete(r)
      if not x.nil?
        x.peer.s_cancel(r.index, r.offset, r.length)
      end
      y = @q.delete(r)
      if not x.nil?
        x.cb.call(false, nil)
      end
      if not y.nil?
        y.cb.call(false, nil)
      end
    end
    update()
  end

  # Called when a peer chokes us
  def cancel(peer)
    canceled = @active.select {|r| r.peer == peer}
    canceled.concat  @q.select {|r| r.peer == peer}
    self.dequeue(canceled)
  end

  private

  def update
    free = @max_size - @active.size
    if free <= 0
      return nil
    end
    to_add = @q.shift(free)
    to_add.each do |r|
      r.peer.s_request(r.index, r.offset, r.length) do |success, data|
        self.dequeue([r])
        r.cb.call(success, data)
      end
    end
    @active.push(*to_add)
  end
end

class UpQueue
  attr_reader :size

  # @param size [Integer] Indicates the maximum number of outstanding requests.
  def initialize(size = 10)
    @max_size = size
    @q = Array.new
    @active = Array.new
  end

  def set_size(size)
    @max_size = size
  end

  # Called when out client wants to upload
  def enqueue(reqs)
    @q.concat(reqs)
    self.update()
  end

  # Called when a request is given up on or completed
  def dequeue(reqs)
    reqs.each {|r| @active.delete(r); @q.delete(r)}
    update()
  end

  # Called when we choke a peer
  def cancel(peer)
    @active.reject! do |r|
      if r.peer == peer
        r.cb.call(false, nil)
        return true
      else
        return false
      end
    end
    @q.reject! do |r|
      if r.peer == peer
        r.cb.call(false, nil)
        return true
      else
        return false
      end
    end
    update()
  end

  private

  def update
    free = @max_size - @active.size
    if free <= 0
      return nil
    end
    to_add = @q.shift(free)
    to_add.each do |r|
      block = r.peer.tor.pdb.read_piece(r.index, r.offset, r.length)
      r.peer.s_piece(r.index, r.offset, block) do
        self.dequeue([r])
      end
    end
    @active.push(*to_add)
  end
end