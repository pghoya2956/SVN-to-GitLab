class Repository < ApplicationRecord
  has_many :jobs, dependent: :destroy
  
  # Layout types constant
  LAYOUT_TYPES = %w[standard non_standard custom].freeze
  
  # Callbacks for cleanup
  before_destroy :cleanup_local_files
  
  validates :name, presence: true
  validates :svn_url, presence: true
  validates :auth_type, inclusion: { in: %w[none basic ssh token] }
  validates :layout_type, inclusion: { in: LAYOUT_TYPES }, allow_nil: true
  
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
    
    # Ensure we always return a HashWithIndifferentAccess for consistent key access
    if svn_structure.is_a?(Hash)
      HashWithIndifferentAccess.new(svn_structure)
    else
      HashWithIndifferentAccess.new(JSON.parse(svn_structure))
    end
  rescue JSON::ParserError
    HashWithIndifferentAccess.new
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
  
  # Get SVN trunk path (커스텀 경로 우선)
  def trunk_path
    custom_trunk_path.presence || parsed_svn_structure.dig('trunk') || 'trunk'
  end
  
  # Get SVN branches path (커스텀 경로 우선)
  def branches_path
    custom_branches_path.presence || parsed_svn_structure.dig('branches') || 'branches'
  end
  
  # Get SVN tags path (커스텀 경로 우선)
  def tags_path
    custom_tags_path.presence || parsed_svn_structure.dig('tags') || 'tags'
  end
  
  # Check if repository can be migrated
  def can_migrate?
    gitlab_project_id.present? && 
    total_revisions.present? && 
    total_revisions > 0
  end
  
  # Check if repository needs redetection
  def needs_redetection?
    return true if last_detected_at.nil?
    return true if updated_at > last_detected_at
    return true if custom_trunk_path_changed?
    return true if custom_branches_path_changed?
    return true if custom_tags_path_changed?
    false
  end
  
  # Git SVN 명령에 사용할 레이아웃 옵션 생성 (단일 원천)
  def git_svn_layout_options
    options = []
    
    # URL에 이미 특정 경로가 포함된 경우 레이아웃 옵션 생략
    # branches/ace_wrapper 같은 경우도 처리
    if svn_url =~ /\/(trunk|branches\/[^\/]+|tags\/[^\/]+)\/?$/ || svn_url =~ /^[^\/]+\/(trunk|branches\/[^\/]+|tags\/[^\/]+)\/?$/
      Rails.logger.info "Repository #{id}: URL contains specific branch/tag path, skipping layout options"
      return options
    end
    
    # 커스텀 레이아웃 우선
    if layout_type == 'custom' && (custom_trunk_path.present? || custom_branches_path.present? || custom_tags_path.present?)
      options << ['--trunk', custom_trunk_path] if custom_trunk_path.present?
      options << ['--branches', custom_branches_path] if custom_branches_path.present?
      options << ['--tags', custom_tags_path] if custom_tags_path.present?
    # 표준 레이아웃
    elsif parsed_svn_structure['layout'] == 'standard' || layout_type == 'standard'
      options << '--stdlayout'
    # SVN 구조 기반
    elsif trunk? || branches? || tags?
      options << ['--trunk', trunk_path] if trunk?
      options << ['--branches', branches_path] if branches?
      options << ['--tags', tags_path] if tags?
    # 기본값
    else
      options << '--stdlayout'
    end
    
    options.flatten
  end
  
  private
  
  def cleanup_local_files
    cleanup_git_repository
    cleanup_authors_file
    cleanup_other_temp_files
  rescue => e
    Rails.logger.error "Error cleaning up files for repository #{id}: #{e.message}"
    # Don't prevent deletion even if cleanup fails
  end
  
  def cleanup_git_repository
    # Job별 디렉토리 구조이므로 전체 repository_{id} 디렉토리를 삭제
    parent_dir = Rails.root.join('git_repos', "repository_#{id}")
    if File.directory?(parent_dir)
      # 모든 job_* 디렉토리가 포함된 상위 디렉토리 삭제
      FileUtils.rm_rf(parent_dir)
      Rails.logger.info "Cleaned up all job directories for repository #{id} at #{parent_dir}"
    end
  end
  
  def cleanup_authors_file
    # Authors 파일 경로들
    authors_paths = [
      Rails.root.join('tmp', 'authors', "repository_#{id}_authors.txt"),
      Rails.root.join('tmp', 'authors_files', "#{id}_authors.txt"),
      authors_file_path  # DB에 저장된 경로가 있으면 그것도 삭제
    ].compact.uniq
    
    authors_paths.each do |path|
      if File.exist?(path)
        File.delete(path)
        Rails.logger.info "Cleaned up authors file at #{path}"
      end
    end
  end
  
  def cleanup_other_temp_files
    # 기타 임시 파일들 (예: 체크포인트 파일 등)
    temp_patterns = [
      Rails.root.join('tmp', "repository_#{id}_*"),
      Rails.root.join('tmp', 'checkpoints', "repository_#{id}_*")
    ]
    
    temp_patterns.each do |pattern|
      Dir.glob(pattern).each do |file|
        File.delete(file) if File.file?(file)
        FileUtils.rm_rf(file) if File.directory?(file)
        Rails.logger.info "Cleaned up temp file/directory at #{file}"
      end
    end
  end
end
