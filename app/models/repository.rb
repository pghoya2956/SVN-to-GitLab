class Repository < ApplicationRecord
  has_many :jobs, dependent: :destroy
  
  validates :name, presence: true
  validates :svn_url, presence: true
  validates :auth_type, inclusion: { in: %w[none basic ssh token] }
  
  # Repository source type
  enum :source_type, {
    svn: 0,
    git: 1
  }, default: :svn
  
  # Migration method for repositories
  enum :migration_method, {
    simple: 0,        # Current method - just copies files
    'git-svn': 1      # git-svn method - preserves full history
  }, default: :simple
  
  # PAT 기반 스코프
  scope :for_token, ->(token_hash) { where(owner_token_hash: token_hash) }
  
  scope :incremental_sync_enabled, -> { where(enable_incremental_sync: true) }
  scope :needs_sync, -> { incremental_sync_enabled.where('last_synced_at IS NULL OR last_synced_at < ?', 1.hour.ago) }
  
  # Decrypt password for use
  def password
    return nil if encrypted_password.blank?
    # In production, use proper encryption/decryption
    # For now, just return as is since we're storing plain text
    encrypted_password
  end
  
  # Check if repository has been initially migrated
  def initial_migration_completed?
    jobs.where(job_type: 'migration', status: 'completed').exists?
  end
  
  # Check if repository needs sync
  def needs_sync?
    return false unless enable_incremental_sync?
    return true if last_synced_at.nil?
    last_synced_at < 1.hour.ago
  end
  
  # Get local git directory path
  def git_directory
    return nil unless local_git_path.present?
    Rails.root.join(local_git_path)
  end
  
  # Check if local git directory exists
  def local_git_exists?
    git_directory.present? && File.directory?(git_directory)
  end
  
  # Check if repository has active jobs
  def has_active_job?
    jobs.active.exists?
  end
  
  # Check if repository has active sync job
  def has_active_sync_job?
    jobs.where(job_type: 'incremental_sync', status: ['pending', 'running']).exists?
  end
  
  # Get last completed migration job
  def last_migration_job
    jobs.where(job_type: 'migration').completed.order(completed_at: :desc).first
  end
  
  # Get last completed sync job
  def last_sync_job
    jobs.where(job_type: 'incremental_sync').completed.order(completed_at: :desc).first
  end
  
  # Helper methods for SVN structure
  def parsed_svn_structure
    return {} unless svn_structure.present?
    return svn_structure if svn_structure.is_a?(Hash)
    JSON.parse(svn_structure)
  rescue JSON::ParserError
    {}
  end
  
  # Set password (encrypt before saving)
  def password=(value)
    # In production, properly encrypt the password
    # For now, just store as is
    self.encrypted_password = value
  end
  
  # SVN structure information access
  def trunk?
    parsed_svn_structure.dig('trunk').present?
  end
  
  def branches?
    parsed_svn_structure.dig('branches').present?
  end
  
  def tags?
    parsed_svn_structure.dig('tags').present?
  end
  
  # Check if repository uses standard layout
  def standard_layout?
    parsed_svn_structure['standard_layout'] == true
  end
  
  # Get SVN trunk path
  def trunk_path
    parsed_svn_structure.dig('trunk') || 'trunk'
  end
  
  # Get SVN branches path
  def branches_path
    parsed_svn_structure.dig('branches') || 'branches'
  end
  
  # Get SVN tags path
  def tags_path
    parsed_svn_structure.dig('tags') || 'tags'
  end
end
