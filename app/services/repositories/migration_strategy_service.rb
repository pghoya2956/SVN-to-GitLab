module Repositories
  class MigrationStrategyService
    MIGRATION_TYPES = {
      'standard' => 'Standard Migration (Full history)',
      'fast' => 'Fast Migration (Limited history)',
      'trunk_only' => 'Trunk Only (No branches/tags)'
    }.freeze
    
    TAG_STRATEGIES = {
      'all' => 'Migrate all tags',
      'recent' => 'Recent tags only (last 6 months)',
      'none' => 'Skip tags'
    }.freeze
    
    BRANCH_STRATEGIES = {
      'all' => 'Migrate all branches',
      'active' => 'Active branches only',
      'trunk' => 'Trunk/master only',
      'none' => 'Skip branches'
    }.freeze
    
    LARGE_FILE_STRATEGIES = {
      'git-lfs' => 'Use Git LFS',
      'exclude' => 'Exclude large files',
      'include' => 'Include as regular files'
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
      
      # Validate tag strategy
      unless TAG_STRATEGIES.keys.include?(@repository.tag_strategy)
        errors << "Invalid tag strategy"
      end
      
      # Validate branch strategy
      unless BRANCH_STRATEGIES.keys.include?(@repository.branch_strategy)
        errors << "Invalid branch strategy"
      end
      
      # Validate large file handling
      unless LARGE_FILE_STRATEGIES.keys.include?(@repository.large_file_handling)
        errors << "Invalid large file handling strategy"
      end
      
      # Validate max file size
      if @repository.max_file_size_mb.to_i <= 0 || @repository.max_file_size_mb.to_i > 1000
        errors << "Max file size must be between 1 and 1000 MB"
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
      # Rough estimation based on repository size and strategy
      base_time = case @repository.migration_type
                  when 'fast' then 5
                  when 'trunk_only' then 2
                  else 10
                  end
      
      # Adjust based on history preservation
      base_time *= 2 if @repository.preserve_history
      
      # Return in minutes
      base_time
    end
    
    def migration_summary
      {
        type: MIGRATION_TYPES[@repository.migration_type],
        preserve_history: @repository.preserve_history,
        tag_strategy: TAG_STRATEGIES[@repository.tag_strategy],
        branch_strategy: BRANCH_STRATEGIES[@repository.branch_strategy],
        large_file_handling: LARGE_FILE_STRATEGIES[@repository.large_file_handling],
        max_file_size_mb: @repository.max_file_size_mb,
        authors_count: parse_authors_mapping.keys.count,
        ignore_patterns_count: parse_ignore_patterns.count,
        estimated_time_minutes: estimated_migration_time
      }
    end
    
    private
    
    def strategy_params(params)
      params.permit(
        :migration_type,
        :preserve_history,
        :authors_mapping,
        :ignore_patterns,
        :tag_strategy,
        :branch_strategy,
        :commit_message_prefix,
        :large_file_handling,
        :max_file_size_mb
      )
    end
  end
end