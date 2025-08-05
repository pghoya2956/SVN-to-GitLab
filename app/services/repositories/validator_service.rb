require 'open3'

module Repositories
  class ValidatorService
    attr_reader :repository, :errors

    def initialize(repository)
      @repository = repository
      @errors = []
    end

    def call
      validate_svn_repository
    end

    private

    def validate_svn_repository
      cmd = build_svn_info_command
      stdout, stderr, status = Open3.capture3(*cmd)

      if status.success?
        parse_svn_info(stdout)
      else
        @errors << parse_error_message(stderr)
        { success: false, errors: @errors }
      end
    rescue => e
      @errors << "Unexpected error: #{e.message}"
      { success: false, errors: @errors }
    end

    def build_svn_info_command
      cmd = ['svn', 'info', repository.svn_url, '--non-interactive']
      
      case repository.auth_type
      when 'basic'
        cmd += ['--username', repository.username, '--password', repository.encrypted_password]
      when 'token'
        cmd += ['--username', repository.username, '--password', repository.encrypted_password]
      end
      
      cmd
    end

    def parse_svn_info(output)
      info = {}
      
      output.each_line do |line|
        case line
        when /^URL:\s+(.+)$/
          info[:url] = $1.strip
        when /^Repository Root:\s+(.+)$/
          info[:root] = $1.strip
        when /^Repository UUID:\s+(.+)$/
          info[:uuid] = $1.strip
        when /^Revision:\s+(\d+)$/
          info[:head_revision] = $1.to_i
        when /^Last Changed Rev:\s+(\d+)$/
          info[:last_changed_rev] = $1.to_i
        when /^Last Changed Date:\s+(.+)$/
          info[:last_changed_date] = $1.strip
        end
      end

      # Get commit count
      commit_count = get_commit_count

      {
        success: true,
        info: info.merge(commit_count: commit_count),
        errors: []
      }
    end

    def get_commit_count
      cmd = ['svn', 'log', repository.svn_url, '--quiet', '--non-interactive']
      
      case repository.auth_type
      when 'basic', 'token'
        cmd += ['--username', repository.username, '--password', repository.encrypted_password]
      end

      stdout, stderr, status = Open3.capture3(*cmd)
      
      if status.success?
        # Count lines that start with 'r' (revision lines)
        stdout.lines.count { |line| line.start_with?('r') }
      else
        0
      end
    rescue
      0
    end

    def parse_error_message(stderr)
      case stderr
      when /authorization failed/i
        "인증 실패: 사용자명과 비밀번호를 확인해주세요"
      when /could not connect to server/i
        "서버 연결 실패: SVN URL을 확인해주세요"
      when /no repository found/i
        "저장소를 찾을 수 없습니다: URL을 확인해주세요"
      when /certificate verification failed/i
        "SSL 인증서 검증 실패"
      else
        stderr.split("\n").first || "알 수 없는 오류가 발생했습니다"
      end
    end
  end
end