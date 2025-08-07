require 'open3'

module Repositories
  class SvnLayoutValidator
    def initialize(repository, trunk_path, branches_path, tags_path)
      @repository = repository
      @trunk_path = trunk_path
      @branches_path = branches_path
      @tags_path = tags_path
    end
    
    def validate
      # Repository가 nil인 경우 체크
      unless @repository
        return {
          valid: false,
          errors: ["Repository not found"],
          paths: {}
        }
      end
      
      results = {
        valid: true,
        errors: [],
        paths: {}
      }
      
      # Trunk 경로 검증 (필수)
      if @trunk_path.present?
        trunk_result = check_svn_path(@trunk_path)
        results[:paths][:trunk] = trunk_result
        
        if trunk_result[:exists]
          results[:paths][:trunk][:message] = "✓ Trunk 경로 확인됨"
        else
          results[:valid] = false
          results[:errors] << "Trunk 경로를 찾을 수 없습니다: #{@trunk_path}"
          results[:paths][:trunk][:message] = "✗ 경로를 찾을 수 없음"
        end
      end
      
      # Branches 경로 검증 (선택)
      if @branches_path.present?
        branches_result = check_svn_path(@branches_path)
        results[:paths][:branches] = branches_result
        
        if branches_result[:exists]
          results[:paths][:branches][:message] = "✓ Branches 경로 확인됨"
        else
          results[:errors] << "Branches 경로를 찾을 수 없습니다: #{@branches_path}"
          results[:paths][:branches][:message] = "✗ 경로를 찾을 수 없음"
        end
      end
      
      # Tags 경로 검증 (선택)
      if @tags_path.present?
        tags_result = check_svn_path(@tags_path)
        results[:paths][:tags] = tags_result
        
        if tags_result[:exists]
          results[:paths][:tags][:message] = "✓ Tags 경로 확인됨"
        else
          results[:errors] << "Tags 경로를 찾을 수 없습니다: #{@tags_path}"
          results[:paths][:tags][:message] = "✗ 경로를 찾을 수 없음"
        end
      end
      
      results
    rescue => e
      {
        valid: false,
        errors: ["검증 중 오류 발생: #{e.message}"],
        paths: {}
      }
    end
    
    private
    
    def check_svn_path(path)
      full_url = "#{@repository.svn_url}/#{path}"
      cmd = build_svn_command(['svn', 'ls', full_url])
      
      stdout, stderr, status = Open3.capture3(*cmd)
      
      if status.success?
        entries = stdout.lines.map(&:strip).reject(&:empty?)
        {
          exists: true,
          entries_count: entries.size,
          sample_entries: entries.first(5)
        }
      else
        {
          exists: false,
          error: stderr.strip
        }
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
  end
end