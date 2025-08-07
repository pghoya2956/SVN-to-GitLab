module Repositories
  class MigrationStrategyService
    MIGRATION_TYPES = {
      'standard' => 'Standard Migration (Full history)',
      'fast' => 'Fast Migration (Limited history)',
      'trunk_only' => 'Trunk Only (No branches/tags)'
    }.freeze
    
    
    def initialize(repository)
      @repository = repository
    end
    
    def update_strategy(params)
      @repository.update(strategy_params(params))
    end
    
    def validate_strategy
      errors = []
      
      # Validate migration type
      unless MIGRATION_TYPES.keys.include?(@repository.migration_type)
        errors << "Invalid migration type"
      end
      
      
      # Validate authors mapping format
      if @repository.authors_mapping.present?
        begin
          parse_authors_mapping
        rescue => e
          errors << "Invalid authors mapping format: #{e.message}"
        end
      end
      
      errors
    end
    
    def parse_authors_mapping
      return {} if @repository.authors_mapping.blank?
      
      mapping = {}
      
      # Handle both Array and String formats
      if @repository.authors_mapping.is_a?(Array)
        # Format from SvnStructureDetector
        @repository.authors_mapping.each do |author|
          if author.is_a?(Hash)
            svn_name = author['svn_name'] || author[:svn_name]
            git_name = author['git_name'] || author[:git_name]
            git_email = author['git_email'] || author[:git_email]
            
            if svn_name && git_name && git_email
              mapping[svn_name] = "#{git_name} <#{git_email}>"
            end
          end
        end
      elsif @repository.authors_mapping.is_a?(String)
        # Original string format
        @repository.authors_mapping.each_line do |line|
          line = line.strip
          next if line.empty? || line.start_with?('#')
          
          parts = line.split('=', 2)
          if parts.length == 2
            svn_author = parts[0].strip
            git_author = parts[1].strip
            
            # Validate git author format
            unless git_author.match?(/^.+ <.+@.+>$/)
              raise "Invalid Git author format for '#{svn_author}'. Expected: 'Name <email@example.com>'"
            end
            
            mapping[svn_author] = git_author
          end
        end
      end
      
      mapping
    end
    
    def parse_ignore_patterns
      return [] if @repository.ignore_patterns.blank?
      
      patterns = []
      @repository.ignore_patterns.each_line do |line|
        line = line.strip
        next if line.empty? || line.start_with?('#')
        patterns << line
      end
      
      patterns
    end
    
    def estimated_migration_time
      # Simple mode는 항상 빠름 (최근 10개 리비전만)
      if @repository.migration_method == 'simple'
        return 5
      end
      
      # Full mode: 리비전 수 기반 추정
      total_revisions = @repository.total_revisions || 1000  # 기본값 1000
      
      # 리비전당 처리 시간 추정 (초)
      # 소규모: 0.5초, 중규모: 1초, 대규모: 2초
      seconds_per_revision = if total_revisions < 1000
                              0.5  # 소규모 프로젝트
                            elsif total_revisions < 5000
                              1.0  # 중규모 프로젝트
                            else
                              2.0  # 대규모 프로젝트
                            end
      
      # Authors 매핑이 많으면 시간 추가 (author 확인 오버헤드)
      if @repository.authors_mapping.present? && @repository.authors_mapping.size > 10
        seconds_per_revision *= 1.2
      end
      
      # 전체 예상 시간 (분)
      estimated_minutes = (total_revisions * seconds_per_revision / 60.0).ceil
      
      # 최소 5분, 최대 480분(8시간)
      [[estimated_minutes, 5].max, 480].min
    end
    
    def migration_summary
      {
        type: MIGRATION_TYPES[@repository.migration_type],
        preserve_history: @repository.preserve_history,
        authors_count: parse_authors_mapping.keys.count,
        ignore_patterns_count: parse_ignore_patterns.count,
        estimated_time_minutes: estimated_migration_time
      }
    end
    
    private
    
    def strategy_params(params)
      params.permit(
        :migration_method,
        :migration_type,
        :preserve_history,
        :authors_mapping,
        :ignore_patterns,
        :generate_gitignore,
        :commit_message_prefix
      )
    end
  end
end