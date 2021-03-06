# redMine - project management software
# Copyright (C) 2006  Jean-Philippe Lang
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.

class Token < ActiveRecord::Base
  belongs_to :user

  @@validity_time = 1.day

  before_create :generate_value

  def generate_value
    self.value = Token.generate_token_value
  end

  # Return true if token has expired
  def expired?
    return Time.now > self.created_at + @@validity_time
  end

  # Delete all expired tokens
  def self.destroy_expired
    Token.delete_all ["action <> 'feeds' AND created_at < ?", Time.now - @@validity_time]
  end

  def to_s
    value
  end

  private

  def self.generate_token_value
    chars = ("a".."z").to_a + ("A".."Z").to_a + ("0".."9").to_a
    token_value = ''
    20.times { |i| token_value << chars[rand(chars.size-1)] }
    token_value
  end
end
