# frozen_string_literal: true

class Strand < Model
  LEASE_EXPIRATION = 120

  def lease
    self.class.lease(id) do
      yield self
    end
  end

  def self.lease(id)
    affected = DB[<<SQL, id].first
UPDATE strand
SET lease = now() + '120 seconds'
WHERE id = ? AND (lease IS NULL OR lease < now())
RETURNING lease
SQL
    return false unless affected
    lease = affected.fetch(:lease)
    yield

    num_updated = DB[<<SQL, id, lease].update
UPDATE strand
SET lease = NULL
WHERE id = ? AND lease = ?
SQL
    fail "BUG: lease violated" unless num_updated == 1
    true
  end

  def load
    Object.const_get("CProg::" + cprog).new(self)
  end
end