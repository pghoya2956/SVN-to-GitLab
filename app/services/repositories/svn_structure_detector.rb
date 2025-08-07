module Repositories
  class SvnStructureDetector
    def initialize(repository, job = nil)
      @repository = repository
      @job = job
    end
    
    def call
      append_output("Starting SVN structure detection...")
      
      {
        success: true,
        structure: detect_structure,
        authors: extract_authors,
        stats: gather_statistics
      }
    rescue => e
      append_output("ERROR: #{e.message}")
      {
        success: false,
        error: e.message
      }
    end
    
    private
    
    def detect_structure
      append_output("Detecting repository structure...")
      
      # First, get root directory listing
      cmd = build_svn_command(['svn', 'ls', @repository.svn_url])
      stdout, _, status = Open3.capture3(*cmd)
      root_entries = status.success? ? stdout.lines.map(&:strip).reject(&:empty?) : []
      
      # Check standard paths
      trunk_info = check_path('trunk')
      branches_info = check_path('branches')
      tags_info = check_path('tags')
      
      layout = determine_layout(trunk_info, branches_info, tags_info)
      
      # Build directory tree structure (2 levels deep) - 간단한 방식으로 수집
      tree_structure = build_simple_tree(@repository.svn_url, root_entries)
      
      structure = {
        trunk: trunk_info[:exists] ? 'trunk' : nil,
        branches: branches_info[:exists] ? 'branches' : nil,
        tags: tags_info[:exists] ? 'tags' : nil,
        layout: layout,
        detected_trunk: trunk_info[:exists] ? 'trunk' : nil,
        detected_branches: branches_info[:exists] ? 'branches' : nil,
        detected_tags: tags_info[:exists] ? 'tags' : nil,
        root_entries: root_entries,  # Always include root entries
        tree_structure: tree_structure  # Include tree structure for visualization
      }
      
      # Add missing directories info for partial_standard
      if layout == 'partial_standard'
        missing = []
        missing << 'trunk' unless trunk_info[:exists]
        missing << 'branches' unless branches_info[:exists]
        missing << 'tags' unless tags_info[:exists]
        structure[:missing_directories] = missing
        
        # Try to detect alternative names in root
        possible_trunk = root_entries.find { |e| e =~ /^(main|master|head|develop|src|code)/i }
        possible_branches = root_entries.find { |e| e =~ /^(branch|feature|release|dev)/i }
        possible_tags = root_entries.find { |e| e =~ /^(tag|release|version)/i }
        
        structure[:alternative_trunk] = possible_trunk if possible_trunk
        structure[:alternative_branches] = possible_branches if possible_branches
        structure[:alternative_tags] = possible_tags if possible_tags
      end
      
      # If non-standard, try to detect actual structure
      if layout == 'non_standard'
        non_standard_info = detect_non_standard_structure
        structure.merge!(non_standard_info)
      end
      
      append_output("Detected layout: #{layout}")
      structure
    end
    
    def check_path(path)
      cmd = build_svn_command(['svn', 'ls', "#{@repository.svn_url}/#{path}"])
      stdout, stderr, status = Open3.capture3(*cmd)
      
      if status.success?
        content = stdout.lines.map(&:strip).reject(&:empty?)
        append_output("Found #{path}: #{content.size} entries")
        
        {
          exists: true,
          content: content,
          count: content.size
        }
      else
        {
          exists: false,
          content: [],
          count: 0
        }
      end
    end
    
    def build_simple_tree(url, root_entries)
      tree = {}
      
      # 루트 엔트리 처리
      root_entries.each do |entry|
        next unless entry.end_with?('/')  # 디렉토리만 처리
        
        dir_name = entry.chomp('/')
        tree[dir_name] = []
        
        # 각 디렉토리의 하위 항목 가져오기 (1 레벨만)
        begin
          cmd = build_svn_command(['svn', 'ls', "#{url}/#{dir_name}"])
          stdout, _, status = Open3.capture3(*cmd)
          
          if status.success?
            stdout.lines.each do |line|
              sub_entry = line.strip
              next if sub_entry.empty?
              tree[dir_name] << sub_entry.chomp('/')
            end
          end
        rescue => e
          append_output("Error getting subdirectories for #{dir_name}: #{e.message}")
        end
      end
      
      tree
    end
    
    def build_directory_tree(url, current_depth: 0, max_depth: 2, path: '', max_entries: 50)
      return [] if current_depth >= max_depth
      
      full_url = path.empty? ? url : "#{url}/#{path}"
      append_output("Building tree for: #{full_url} (depth: #{current_depth})")
      
      cmd = build_svn_command(['svn', 'ls', full_url])
      stdout, _, status = Open3.capture3(*cmd)
      
      return [] unless status.success?
      
      entries = []
      entry_count = 0
      
      stdout.lines.each do |line|
        entry_name = line.strip
        next if entry_name.empty?
        
        # Limit entries per directory to avoid performance issues
        break if entry_count >= max_entries
        
        is_dir = entry_name.end_with?('/')
        clean_name = entry_name.chomp('/')
        full_path = path.empty? ? clean_name : "#{path}/#{clean_name}"
        
        # Skip hidden directories and files
        next if clean_name.start_with?('.')
        
        entry = {
          name: clean_name,
          path: full_path,
          type: is_dir ? 'directory' : 'file'
        }
        
        # Recursively get subdirectories (but not files)
        if is_dir && current_depth < max_depth - 1
          children = build_directory_tree(url, 
                                        current_depth: current_depth + 1, 
                                        max_depth: max_depth, 
                                        path: full_path,
                                        max_entries: 30)  # Fewer entries for subdirectories
          entry[:children] = children if children.any?
        end
        
        entries << entry
        entry_count += 1
      end
      
      append_output("Found #{entries.size} entries at depth #{current_depth}")
      entries
    rescue => e
      append_output("Error building tree for #{path}: #{e.message}")
      []
    end
    
    def detect_non_standard_structure
      append_output("Checking for non-standard structure...")
      
      cmd = build_svn_command(['svn', 'ls', @repository.svn_url])
      stdout, _, status = Open3.capture3(*cmd)
      
      return {} unless status.success?
      
      # Look for common patterns
      entries = stdout.lines.map(&:strip).reject(&:empty?)
      
      possible_trunk = entries.find { |e| e =~ /^(trunk|main|master|head|develop)/i }
      possible_branches = entries.find { |e| e =~ /^(branches|branch|releases)/i }
      possible_tags = entries.find { |e| e =~ /^(tags|tag|releases)/i }
      
      {
        detected_trunk: possible_trunk,
        detected_branches: possible_branches,
        detected_tags: possible_tags,
        root_entries: entries,
        requires_user_input: true  # 비표준 레이아웃은 사용자 입력 필요
      }
    end
    
    def extract_authors
      append_output("Extracting author information from entire repository history...")
      
      # Get ALL authors from entire history (no limit)
      cmd = build_svn_command(['svn', 'log', '--quiet', @repository.svn_url])
      stdout, _, status = Open3.capture3(*cmd)
      
      return [] unless status.success?
      
      # Parse authors from log
      authors = stdout.lines
        .select { |line| line =~ /^r\d+ \| .+ \|/ }
        .map { |line| line.split('|')[1].strip }
        .reject(&:empty?)
        .uniq
        .sort
      
      append_output("Found #{authors.size} unique authors from complete history")
      
      # Create author mappings
      authors.map do |author|
        {
          svn_name: author,
          git_name: author,
          git_email: "#{author.downcase.gsub(/[^a-z0-9]/, '')}@example.com"
        }
      end
    end
    
    def gather_statistics
      append_output("Gathering repository statistics...")
      
      cmd = build_svn_command(['svn', 'info', @repository.svn_url])
      stdout, _, status = Open3.capture3(*cmd)
      
      return {} unless status.success?
      
      info = {}
      stdout.lines.each do |line|
        case line
        when /^Revision: (\d+)/
          info[:latest_revision] = $1.to_i
        when /^Last Changed Date: (.+)/
          info[:last_changed] = $1.strip
        when /^Repository Root: (.+)/
          info[:repository_root] = $1.strip
        when /^Repository UUID: (.+)/
          info[:repository_uuid] = $1.strip
        end
      end
      
      # Get repository size estimate
      if info[:latest_revision]
        append_output("Latest revision: #{info[:latest_revision]}")
      end
      
      info
    end
    
    def determine_layout(trunk, branches, tags)
      if trunk[:exists] && (branches[:exists] || tags[:exists])
        'standard'
      elsif trunk[:exists] || branches[:exists] || tags[:exists]
        'partial_standard'
      else
        'non_standard'
      end
    end
    
    def build_svn_command(cmd)
      # Add authentication if needed
      if @repository.auth_type == 'basic'
        cmd.insert(-2, '--username', @repository.username) if @repository.username.present?
        cmd.insert(-2, '--password', @repository.password) if @repository.password.present?
      end
      
      # Add common options
      cmd.insert(-2, '--non-interactive')
      cmd.insert(-2, '--trust-server-cert-failures=unknown-ca,cn-mismatch,expired,not-yet-valid,other')
      
      cmd
    end
    
    def append_output(message)
      return unless @job
      @job.append_output("[SvnStructureDetector] #{message}")
    end
  end
end