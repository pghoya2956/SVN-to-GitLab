module Repositories
  class SvnStructureDetector
    def initialize(repository, job = nil)
      @repository = repository
      @job = job
    end
    
    def call
      append_output("Starting SVN structure detection...")
      
      structure = detect_structure
      stats = gather_statistics
      
      # Calculate revisions based on paths
      total_revisions = calculate_revisions
      stats[:total_revisions] = total_revisions if total_revisions > 0
      
      {
        success: true,
        structure: structure,
        authors: extract_authors,
        stats: stats,
        total_revisions: total_revisions
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
    
    def calculate_revisions
      append_output("=" * 60)
      append_output("📊 리비전 계산 시작...")
      append_output("=" * 60)
      
      # For custom layout, ONLY use explicitly configured paths
      # For standard layout, use detected structure
      if @repository.layout_type == 'custom'
        trunk_path = @repository.custom_trunk_path.presence
        branches_path = @repository.custom_branches_path.presence
        tags_path = @repository.custom_tags_path.presence
        append_output("")
        append_output("📋 레이아웃 타입: 커스텀 (사용자 정의)")
        append_output("✅ 사용자가 설정한 경로만 사용합니다:")
        append_output("  • Trunk: #{trunk_path ? "✅ #{trunk_path}" : '❌ 설정 안됨'}")
        append_output("  • Branches: #{branches_path ? "✅ #{branches_path}" : '❌ 설정 안됨'}")
        append_output("  • Tags: #{tags_path ? "✅ #{tags_path}" : '❌ 설정 안됨'}")
      else
        # For standard/auto-detected layouts, use detected structure
        trunk_path = @repository.custom_trunk_path.presence || @repository.parsed_svn_structure['trunk']
        branches_path = @repository.custom_branches_path.presence || @repository.parsed_svn_structure['branches']
        tags_path = @repository.custom_tags_path.presence || @repository.parsed_svn_structure['tags']
        append_output("")
        append_output("📋 레이아웃 타입: 표준/자동감지")
        append_output("✅ 감지된 구조 또는 커스텀 경로 사용:")
        append_output("  • Trunk: #{trunk_path ? "✅ #{trunk_path}" : '❌ 없음'}")
        append_output("  • Branches: #{branches_path ? "✅ #{branches_path}" : '❌ 없음'}")
        append_output("  • Tags: #{tags_path ? "✅ #{tags_path}" : '❌ 없음'}")
      end
      
      append_output("")
      append_output("-" * 60)
      
      # Special case: entire repository as trunk
      if trunk_path == '.'
        append_output("⚠️ 특수 케이스: 전체 저장소를 Trunk로 사용")
        append_output("🔍 전체 저장소의 리비전을 계산합니다...")
        total = get_total_revisions(@repository.svn_url)
        append_output("✅ 전체 저장소 리비전: #{total}")
        append_output("")
        append_output("=" * 60)
        append_output("📊 최종 결과: #{total} 리비전")
        append_output("=" * 60)
        return total
      end
      
      # Only trunk specified
      if trunk_path.present? && branches_path.blank? && tags_path.blank?
        append_output("📍 단일 경로 모드: Trunk만 설정됨")
        append_output("🔍 #{trunk_path} 경로의 리비전을 계산합니다...")
        trunk_rev = get_path_revisions("#{@repository.svn_url}/#{trunk_path}")
        append_output("✅ Trunk 리비전: #{trunk_rev}")
        append_output("")
        append_output("=" * 60)
        append_output("📊 최종 결과: #{trunk_rev} 리비전 (Trunk 경로만 마이그레이션)")
        append_output("=" * 60)
        return trunk_rev
      end
      
      # Multiple paths specified - get maximum revision
      append_output("📍 다중 경로 모드: 여러 경로가 설정됨")
      append_output("🔍 각 경로의 리비전을 계산합니다...")
      append_output("")
      
      revisions = {}
      
      if trunk_path.present? && trunk_path != '.'
        append_output("🔄 Trunk 경로 확인 중: #{trunk_path}")
        trunk_rev = get_path_revisions("#{@repository.svn_url}/#{trunk_path}")
        if trunk_rev > 0
          append_output("  ✅ Trunk 리비전: #{trunk_rev}")
          revisions[:trunk] = trunk_rev
        else
          append_output("  ❌ Trunk 경로를 찾을 수 없음")
        end
        append_output("")
      end
      
      if branches_path.present?
        append_output("🔄 Branches 경로 확인 중: #{branches_path}")
        branches_rev = get_max_branch_revision("#{@repository.svn_url}/#{branches_path}")
        if branches_rev > 0
          append_output("  ✅ Branches 최대 리비전: #{branches_rev}")
          revisions[:branches] = branches_rev
        else
          append_output("  ❌ Branches 경로를 찾을 수 없거나 비어있음")
        end
        append_output("")
      end
      
      if tags_path.present?
        append_output("🔄 Tags 경로 확인 중: #{tags_path}")
        tags_rev = get_max_tag_revision("#{@repository.svn_url}/#{tags_path}")
        if tags_rev > 0
          append_output("  ✅ Tags 최대 리비전: #{tags_rev}")
          revisions[:tags] = tags_rev
        else
          append_output("  ❌ Tags 경로를 찾을 수 없거나 비어있음")
        end
        append_output("")
      end
      
      if revisions.empty?
        max_revision = get_total_revisions(@repository.svn_url)
        append_output("⚠️ 특정 경로를 찾을 수 없어 전체 저장소 리비전 사용: #{max_revision}")
      else
        max_revision = revisions.values.max
        max_source = revisions.key(max_revision)
        
        append_output("=" * 60)
        append_output("📊 리비전 계산 결과:")
        append_output("=" * 60)
        append_output("")
        append_output("  Trunk:    #{revisions[:trunk] ? sprintf('%6d', revisions[:trunk]) : '     -'} 리비전")
        append_output("  Branches: #{revisions[:branches] ? sprintf('%6d', revisions[:branches]) : '     -'} 리비전")
        append_output("  Tags:     #{revisions[:tags] ? sprintf('%6d', revisions[:tags]) : '     -'} 리비전")
        append_output("")
        append_output("  🏆 최대값: #{max_source.to_s.capitalize} (#{max_revision} 리비전)")
        append_output("")
        append_output("💡 설명: git-svn은 모든 경로의 히스토리를 포함해야 하므로")
        append_output("         가장 큰 리비전 번호를 사용합니다.")
        append_output("")
        append_output("=" * 60)
        append_output("📊 최종 마이그레이션 리비전: #{max_revision}")
        append_output("=" * 60)
      end
      
      max_revision
    end
    
    def get_total_revisions(url)
      cmd = build_svn_command(['svn', 'info', url])
      stdout, _, status = Open3.capture3(*cmd)
      
      return 0 unless status.success?
      
      if stdout =~ /Last Changed Rev: (\d+)/
        $1.to_i
      elsif stdout =~ /Revision: (\d+)/
        $1.to_i
      else
        0
      end
    end
    
    def get_path_revisions(url)
      cmd = build_svn_command(['svn', 'info', url])
      stdout, stderr, status = Open3.capture3(*cmd)
      
      unless status.success?
        append_output("Failed to get info for #{url}: #{stderr}")
        return 0
      end
      
      if stdout =~ /Last Changed Rev: (\d+)/
        $1.to_i
      elsif stdout =~ /Revision: (\d+)/
        $1.to_i
      else
        0
      end
    end
    
    def get_max_branch_revision(branches_url)
      cmd = build_svn_command(['svn', 'ls', branches_url])
      stdout, stderr, status = Open3.capture3(*cmd)
      
      unless status.success?
        append_output("Failed to list branches: #{stderr}")
        return 0
      end
      
      branches = stdout.lines.map(&:strip).reject(&:empty?)
      return 0 if branches.empty?
      
      max_rev = 0
      branches.each do |branch|
        next unless branch.end_with?('/')
        branch_name = branch.chomp('/')
        branch_rev = get_path_revisions("#{branches_url}/#{branch_name}")
        max_rev = branch_rev if branch_rev > max_rev
      end
      
      max_rev
    end
    
    def get_max_tag_revision(tags_url)
      cmd = build_svn_command(['svn', 'ls', tags_url])
      stdout, stderr, status = Open3.capture3(*cmd)
      
      unless status.success?
        append_output("Failed to list tags: #{stderr}")
        return 0
      end
      
      tags = stdout.lines.map(&:strip).reject(&:empty?)
      return 0 if tags.empty?
      
      max_rev = 0
      tags.each do |tag|
        next unless tag.end_with?('/')
        tag_name = tag.chomp('/')
        tag_rev = get_path_revisions("#{tags_url}/#{tag_name}")
        max_rev = tag_rev if tag_rev > max_rev
      end
      
      max_rev
    end
    
    def append_output(message)
      return unless @job
      @job.append_output("[SvnStructureDetector] #{message}")
      
      # 실시간으로 진행 상황을 브로드캐스트
      ActionCable.server.broadcast(
        "repository_#{@repository.id}",
        {
          type: 'structure_detection_progress',
          message: message,
          job_id: @job.id
        }
      )
    rescue => e
      # 브로드캐스트 실패는 무시 (로그는 계속 기록)
      Rails.logger.error "Failed to broadcast: #{e.message}"
    end
  end
end