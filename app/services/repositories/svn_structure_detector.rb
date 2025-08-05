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
      
      # Check standard paths
      trunk_info = check_path('trunk')
      branches_info = check_path('branches')
      tags_info = check_path('tags')
      
      layout = determine_layout(trunk_info, branches_info, tags_info)
      
      structure = {
        trunk: trunk_info[:exists] ? 'trunk' : nil,
        branches: branches_info[:exists] ? 'branches' : nil,
        tags: tags_info[:exists] ? 'tags' : nil,
        layout: layout
      }
      
      # If non-standard, try to detect actual structure
      if layout == 'non_standard'
        structure.merge!(detect_non_standard_structure)
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
        root_entries: entries
      }
    end
    
    def extract_authors
      append_output("Extracting author information...")
      
      # Limit log entries for performance
      cmd = build_svn_command(['svn', 'log', '--quiet', '--limit', '1000', @repository.svn_url])
      stdout, _, status = Open3.capture3(*cmd)
      
      return [] unless status.success?
      
      # Parse authors from log
      authors = stdout.lines
        .select { |line| line =~ /^r\d+ \| .+ \|/ }
        .map { |line| line.split('|')[1].strip }
        .reject(&:empty?)
        .uniq
        .sort
      
      append_output("Found #{authors.size} unique authors")
      
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