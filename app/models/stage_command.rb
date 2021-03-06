# frozen_string_literal: true
class StageCommand < ActiveRecord::Base
  has_soft_deletion default_scope: true
  include SoftDeleteWithDestroy

  belongs_to :stage
  belongs_to :command, autosave: true
end
